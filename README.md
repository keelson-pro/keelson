# Keelson

A Kubernetes image-update controller. Watches annotated workloads, queries
registries for newer tags, patches the workload when a newer tag meets the
configured policy.


# Naming

Keelson is the part of a boat directly above and on top of the [keel](https://keel.sh).


# Origin

Keelson was born while working with an AKS cluster that had cluster wide pull
permissions and no imagePullSecrets specified. The logging, the documentation
and the community support were all weak. When faced with a time pressure and a
desire to do things right and leave the customer with a great system, this was
not ideal. The final thing lacking in keel was job support, this [open ticket](https://github.com/keel-hq/keel/issues/352)
illustrates the issue. No progress in over 7 years since the ticket was opened.


## Contents

- **Scripts** (`src/scripts`) - bash runtime.
- **Library** (`src/scripts/lib`) - bash scripts sourced by runtime scripts
- **Manifests** (`src/kubernetes/` and generated) - templated with `${Environment}`.


## Tech stack

Bash, kubectl, yq 4, skopeo. Everything runs in containers. Tests: BATS. Lint: shellcheck.


## Configuration

See [Configuration.md](Configuration.md) for environment variables, the
`registries.yaml` shape and auth modes, and the per-workload annotations
Keelson honours.
