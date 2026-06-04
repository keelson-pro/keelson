#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../scripts"
    # shellcheck source=../scripts/lib/managedfields.bash
    source "$SCRIPT_DIR/lib/managedfields.bash"
}

# Deployment-shape managedFields entry owned by argocd via SSA.
argocd_deployment_mf() {
    cat <<'JSON'
[
  {
    "manager": "argocd-application-controller",
    "operation": "Apply",
    "apiVersion": "apps/v1",
    "fieldsV1": {
      "f:spec": {
        "f:template": {
          "f:spec": {
            "f:containers": {
              "k:{\"name\":\"main\"}": {
                "f:image": {}
              }
            }
          }
        }
      }
    }
  }
]
JSON
}

# Helm/kubectl-style entry, Update operation.
kubectl_deployment_mf() {
    cat <<'JSON'
[
  {
    "manager": "kubectl-client-side-apply",
    "operation": "Update",
    "apiVersion": "apps/v1",
    "fieldsV1": {
      "f:spec": {
        "f:template": {
          "f:spec": {
            "f:containers": {
              "k:{\"name\":\"main\"}": {
                "f:image": {}
              }
            }
          }
        }
      }
    }
  }
]
JSON
}

# Two managers - flux owns image, kube-controller-manager owns replicas only.
multi_manager_mf() {
    cat <<'JSON'
[
  {
    "manager": "kube-controller-manager",
    "operation": "Update",
    "fieldsV1": {
      "f:status": { "f:replicas": {} }
    }
  },
  {
    "manager": "flux",
    "operation": "Apply",
    "fieldsV1": {
      "f:spec": {
        "f:template": {
          "f:spec": {
            "f:containers": {
              "k:{\"name\":\"web\"}": {
                "f:image": {}
              }
            }
          }
        }
      }
    }
  }
]
JSON
}

@test "owner_of_image: finds argocd Apply owner" {
    run managedfields_owner_of_image "$(argocd_deployment_mf)" main
    [ "$status" -eq 0 ]
    [ "$output" = "argocd-application-controller Apply" ]
}

@test "owner_of_image: finds kubectl Update owner" {
    run managedfields_owner_of_image "$(kubectl_deployment_mf)" main
    [ "$status" -eq 0 ]
    [ "$output" = "kubectl-client-side-apply Update" ]
}

@test "owner_of_image: returns the manager that owns the container's image, not unrelated managers" {
    run managedfields_owner_of_image "$(multi_manager_mf)" web
    [ "$status" -eq 0 ]
    [ "$output" = "flux Apply" ]
}

@test "owner_of_image: container name mismatch returns nothing" {
    run managedfields_owner_of_image "$(argocd_deployment_mf)" sidecar
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "owner_of_image: empty managedFields returns nothing" {
    run managedfields_owner_of_image "[]" main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "owner_of_image: empty input returns nothing" {
    run managedfields_owner_of_image "" main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "owner_of_image: CronJob jobTemplate-nested ownership also detected" {
    local mf
    mf=$(cat <<'JSON'
[
  {
    "manager": "flux",
    "operation": "Apply",
    "fieldsV1": {
      "f:spec": {
        "f:jobTemplate": {
          "f:spec": {
            "f:template": {
              "f:spec": {
                "f:containers": {
                  "k:{\"name\":\"worker\"}": {
                    "f:image": {}
                  }
                }
              }
            }
          }
        }
      }
    }
  }
]
JSON
)
    run managedfields_owner_of_image "$mf" worker
    [ "$status" -eq 0 ]
    [ "$output" = "flux Apply" ]
}
