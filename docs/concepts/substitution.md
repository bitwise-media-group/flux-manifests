# The empty-var convention

Every component's Kustomization substitutes the `cluster-vars` ConfigMap into its manifests
(`postBuild.substituteFrom`). Two properties of that substitution shape how variables are written everywhere in this
repository.

## Strict substitution

kustomize-controller substitutes in **strict** mode. A bare `${VAR}` fails the whole Kustomization when `VAR` isn't
published. A `${VAR:=default}` never fails, because `:=` satisfies strict mode even when the variable is unset.

That's why the [layout rules](layout.md#the-rules) care where defaults appear: a default hides a missing variable, so
it's only allowed where a variable is genuinely optional.

## Empty values become null

The controller doesn't substitute text directly. It parses each manifest, serialises it back to YAML, substitutes, and
parses the result again. The serialise step drops quotes it considers redundant, so in **structured** YAML:

```yaml
key: "${VAR}"
```

becomes `key: ${VAR}` before substitution and, when `VAR` is empty, `key:`, which parses as **null**. Helm schemas and
CRDs then reject the key, and the Kustomization fails on the cluster even though the manifest looks correctly quoted.

This applies to plain manifests and to the structured parts of a ResourceSet (`spec.resources`, `spec.inputs`). It does
not apply inside a `resourcesTemplate: |` block scalar, which is a single string, so quotes inside it are literal text
and survive.

## The convention

A variable that can legally be empty on its tree must never appear as a bare quoted scalar in structured YAML. In order
of preference:

1. **Key absent when empty.** Use a conditional flow mapping or a template gate when the consumer treats empty as off.
2. **Template-quote it.** `<< "${VAR:=}" | quote >>` when the field must exist as a string under a strict chart schema.
3. **Move it into a `resourcesTemplate: |` block**, where quotes are literal text.

The dex ServiceAccount annotation is an example of the first: the annotation map is empty, not a null value, on clusters
without a directory service account.

```yaml
annotations:
  << if ne "${DEX_DIRECTORY_SA:=}" "" >>{"iam.gke.io/gcp-service-account":"${DEX_DIRECTORY_SA:=}"}<< else >>{}<< end >>
```

Related habits you'll see throughout the components:

- **Compare variables inline in the template text**, never through `spec.inputs`. The roundtrip re-types input values:
  an empty value becomes null (and `missingkey=error` fails the render), and `true`/`false` become booleans that break
  string comparison. `<< if eq "${GATEWAY_API_CRDS}" "true" >>` is the safe form.
- **JSON variables** (`DEX_CONNECTORS`, `DEX_CLIENTS`) are wrapped in Go raw-string backticks,
  ``mustFromJson `${DEX_CLIENTS:=[]}` ``, so the JSON's own double quotes can't end the string early.
- **dex's `$VAR` references** are deliberately brace-less, so Flux's substitution (which only touches `${…}`) leaves
  them for dex to expand.

## How it's enforced

`make test` substitutes exactly the way the controller does: it normalises scalar styles first (dropping redundant
quotes), then substitutes textually. A quoted empty variable therefore becomes null locally just as it would on a
cluster, and the **null guard** fails the run, naming the file and the path. The guard self-tests at startup by feeding
itself a canary that must trip, so it can't silently stop working. See [Validation](validation.md).
