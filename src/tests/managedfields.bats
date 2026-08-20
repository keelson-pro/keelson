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
    "time": "2026-04-01T10:00:00Z",
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

# Helm/kubectl-style entry, Update operation. Under the new strategy this
# should NOT surface as an Apply owner - Update-op entries are treated as
# "no Apply owner" and route to the UNOWNED strategy.
kubectl_deployment_mf() {
    cat <<'JSON'
[
  {
    "manager": "kubectl-client-side-apply",
    "operation": "Update",
    "apiVersion": "apps/v1",
    "time": "2026-04-01T10:00:00Z",
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
    "time": "2026-04-01T10:00:00Z",
    "fieldsV1": {
      "f:status": { "f:replicas": {} }
    }
  },
  {
    "manager": "flux",
    "operation": "Apply",
    "time": "2026-04-01T10:00:00Z",
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

# Two Apply-op managers on the same image field; the newer one should win.
two_apply_owners_mf() {
    cat <<'JSON'
[
  {
    "manager": "old-controller",
    "operation": "Apply",
    "time": "2026-01-01T00:00:00Z",
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
  },
  {
    "manager": "new-controller",
    "operation": "Apply",
    "time": "2026-04-01T10:00:00Z",
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

# An Apply owner that claims an init container's image instead.
argocd_init_container_mf() {
    cat <<'JSON'
[
  {
    "manager": "argocd-application-controller",
    "operation": "Apply",
    "apiVersion": "apps/v1",
    "time": "2026-04-01T10:00:00Z",
    "fieldsV1": {
      "f:spec": {
        "f:template": {
          "f:spec": {
            "f:initContainers": {
              "k:{\"name\":\"migrate\"}": {
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

@test "apply_owner_of_image: an init container's owner lives under f:initContainers" {
    run managedfields_apply_owner_of_image "$(argocd_init_container_mf)" initContainers migrate
    [ "$status" -eq 0 ]
    [ "$output" = "argocd-application-controller" ]
}

@test "apply_owner_of_image: looking in the wrong list finds no owner" {
    # Getting this wrong is not a miss, it is a refusal: mimic requires an
    # Apply owner and declines the update when it cannot find one.
    run managedfields_apply_owner_of_image "$(argocd_init_container_mf)" containers migrate
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply_owner_of_image: finds argocd Apply owner" {
    run managedfields_apply_owner_of_image "$(argocd_deployment_mf)" containers main
    [ "$status" -eq 0 ]
    [ "$output" = "argocd-application-controller" ]
}

@test "apply_owner_of_image: Update-op owner is not returned (routes to UNOWNED)" {
    run managedfields_apply_owner_of_image "$(kubectl_deployment_mf)" containers main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply_owner_of_image: returns the Apply owner that owns the container's image" {
    run managedfields_apply_owner_of_image "$(multi_manager_mf)" containers web
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}

@test "apply_owner_of_image: multiple Apply owners -> most recent wins" {
    run managedfields_apply_owner_of_image "$(two_apply_owners_mf)" containers main
    [ "$status" -eq 0 ]
    [ "$output" = "new-controller" ]
}

@test "apply_owner_of_image: container name mismatch returns nothing" {
    run managedfields_apply_owner_of_image "$(argocd_deployment_mf)" containers sidecar
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply_owner_of_image: empty managedFields returns nothing" {
    run managedfields_apply_owner_of_image "[]" containers main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply_owner_of_image: empty input returns nothing" {
    run managedfields_apply_owner_of_image "" containers main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply_owner_of_image: CronJob jobTemplate-nested ownership also detected" {
    local mf
    mf=$(cat <<'JSON'
[
  {
    "manager": "flux",
    "operation": "Apply",
    "time": "2026-04-01T10:00:00Z",
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
    run managedfields_apply_owner_of_image "$mf" containers worker
    [ "$status" -eq 0 ]
    [ "$output" = "flux" ]
}
