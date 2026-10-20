#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Keelson contributors (Fred Cooke)

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

# Helm/kubectl-style entry, Update operation: an update-owned image, which
# routes to the UPDATE_OWNED strategy.
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

@test "image_owner: an init container's owner lives under f:initContainers" {
    managedfields_image_owner "$(argocd_init_container_mf)" initContainers migrate
    [ "$MANAGEDFIELDS_OWNER" = "argocd-application-controller" ]
}

@test "image_owner: looking in the wrong list finds no owner" {
    # Getting this wrong is not a miss: the image reads as unowned and is
    # claimed instead of written as its owner.
    managedfields_image_owner "$(argocd_init_container_mf)" containers migrate
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: finds argocd Apply owner" {
    managedfields_image_owner "$(argocd_deployment_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER" = "argocd-application-controller" ]
}

@test "image_owner: an Update-op owner is returned with its operation" {
    managedfields_image_owner "$(kubectl_deployment_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER" = "kubectl-client-side-apply" ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = "Update" ]
}

@test "image_owner: an Apply owner is returned with its operation" {
    managedfields_image_owner "$(argocd_deployment_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = "Apply" ]
}

@test "image_owner: nobody owning the image leaves both empty" {
    MANAGEDFIELDS_OWNER=stale
    MANAGEDFIELDS_OWNER_OPERATION=stale
    managedfields_image_owner '[{"manager":"m","operation":"Apply","fieldsV1":{"f:spec":{"f:replicas":{}}}}]' containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
    [ -z "$MANAGEDFIELDS_OWNER_OPERATION" ]
}

@test "image_owner: a subresource entry is not the object's owner" {
    managedfields_image_owner '[{"manager":"m","operation":"Apply","subresource":"status","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: returns the Apply owner that owns the container's image" {
    managedfields_image_owner "$(multi_manager_mf)" containers web
    [ "$MANAGEDFIELDS_OWNER" = "flux" ]
}

@test "image_owner: multiple Apply owners -> most recent wins" {
    managedfields_image_owner "$(two_apply_owners_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER" = "new-controller" ]
}

@test "image_owner: container name mismatch returns nothing" {
    managedfields_image_owner "$(argocd_deployment_mf)" containers sidecar
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: empty managedFields returns nothing" {
    managedfields_image_owner "[]" containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: empty input returns nothing" {
    managedfields_image_owner "" containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: CronJob jobTemplate-nested ownership also detected" {
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
    managedfields_image_owner "$mf" containers worker
    [ "$MANAGEDFIELDS_OWNER" = "flux" ]
}

# Equal timestamps were undocumented and untested: the comparison is strictly
# greater, so the earlier entry keeps the field.
equal_time_mf() {
    cat <<'JSON'
[
  {
    "manager": "first-controller",
    "operation": "Apply",
    "time": "2026-04-01T10:00:00Z",
    "fieldsV1": {"f:spec":{"f:template":{"f:spec":{"f:containers":{
      "k:{\"name\":\"main\"}": {"f:image": {}}}}}}}
  },
  {
    "manager": "second-controller",
    "operation": "Apply",
    "time": "2026-04-01T10:00:00Z",
    "fieldsV1": {"f:spec":{"f:template":{"f:spec":{"f:containers":{
      "k:{\"name\":\"main\"}": {"f:image": {}}}}}}}
  }
]
JSON
}

# An Apply owner with no time at all, alongside one that has a time.
untimed_owner_mf() {
    cat <<'JSON'
[
  {
    "manager": "untimed-controller",
    "operation": "Apply",
    "fieldsV1": {"f:spec":{"f:template":{"f:spec":{"f:containers":{
      "k:{\"name\":\"main\"}": {"f:image": {}}}}}}}
  }
]
JSON
}

@test "image_owner: equal timestamps keep the earlier entry" {
    managedfields_image_owner "$(equal_time_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER" = "first-controller" ]
}

@test "image_owner: an Apply owner with no time still wins alone" {
    managedfields_image_owner "$(untimed_owner_mf)" containers main
    [ "$MANAGEDFIELDS_OWNER" = "untimed-controller" ]
}

@test "image_owner: an Update entry never beats an older Apply" {
    local mf
    mf=$(cat <<'JSON'
[
  {
    "manager": "old-apply",
    "operation": "Apply",
    "time": "2026-01-01T00:00:00Z",
    "fieldsV1": {"f:spec":{"f:template":{"f:spec":{"f:containers":{
      "k:{\"name\":\"main\"}": {"f:image": {}}}}}}}
  },
  {
    "manager": "recent-update",
    "operation": "Update",
    "time": "2026-09-01T00:00:00Z",
    "fieldsV1": {"f:spec":{"f:template":{"f:spec":{"f:containers":{
      "k:{\"name\":\"main\"}": {"f:image": {}}}}}}}
  }
]
JSON
)
    managedfields_image_owner "$mf" containers main
    [ "$MANAGEDFIELDS_OWNER" = "old-apply" ]
}

@test "image_owner: an Apply entry owning no image field is ignored" {
    local mf
    mf=$(cat <<'JSON'
[
  {
    "manager": "replicas-owner",
    "operation": "Apply",
    "time": "2026-09-01T00:00:00Z",
    "fieldsV1": {"f:spec":{"f:replicas": {}}}
  }
]
JSON
)
    managedfields_image_owner "$mf" containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

# --- image volumes own a field one level deeper ---

@test "image_owner: an image volume owner is found under f:volumes" {
    local mf='[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"vol\"}":{"f:image":{"f:reference":{}}}}}}}}}]'
    managedfields_image_owner "$mf" imageVolumes vol
    [ "$MANAGEDFIELDS_OWNER" = "argocd-application-controller" ]
}

@test "image_owner: a container owner is not matched for a volume of that name" {
    local mf='[{"manager":"argocd-application-controller","operation":"Apply","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"vol\"}":{"f:image":{}}}}}}}}]'
    managedfields_image_owner "$mf" imageVolumes vol
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: owning only a volume's pull policy is not owning its image" {
    # A later manager that set image.pullPolicy holds f:image, but not the
    # reference: the reference's owner is still the earlier one.
    local mf='[{"manager":"helm","operation":"Update","time":"2026-04-01T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"vol\"}":{"f:image":{"f:reference":{}}}}}}}}},{"manager":"tuner","operation":"Update","time":"2026-04-02T10:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"vol\"}":{"f:image":{"f:pullPolicy":{}}}}}}}}}]'
    managedfields_image_owner "$mf" imageVolumes vol
    [ "$MANAGEDFIELDS_OWNER" = "helm" ]
}

# --- managedfields_owner_set / managedfields_project ---

fixture_json() {
    yq -o=json -I0 "${BATS_TEST_DIRNAME}/fixtures/managedfields/$1.yaml"
}
KAPTAIN=kaptain/meta-env/run-platform-nonprod

@test "owner_set: the owner's Apply entry, keys sorted" {
    managedfields_owner_set "$(fixture_json run-stage)" "$KAPTAIN"
    [[ "$MANAGEDFIELDS_OWNER_SET" == '{"f:metadata":{"f:annotations":{"f:kaptain.org/build-timestamp":{}'* ]]
}

@test "owner_set: the same set in another key order compares equal" {
    managedfields_owner_set "$(fixture_json run-stage)" "$KAPTAIN"
    local a=$MANAGEDFIELDS_OWNER_SET
    managedfields_owner_set "$(fixture_json run-stage | yq -p=json -o=json -I0 '.metadata.managedFields[0].fieldsV1 |= (to_entries | reverse | from_entries)')" "$KAPTAIN"
    [ "$MANAGEDFIELDS_OWNER_SET" = "$a" ]
}

@test "owner_set: a manager with no entry is refused" {
    if managedfields_owner_set "$(fixture_json run-stage)" nobody; then false; fi
    [ -z "$MANAGEDFIELDS_OWNER_SET" ]
}

@test "owner_set: an Update entry under the name does not count" {
    # On the object itself, not a subresource, so only the operation can
    # be what rules it out.
    if managedfields_owner_set '{"metadata":{"managedFields":[{"manager":"m","operation":"Update","fieldsV1":{"f:spec":{"f:replicas":{}}}}]}}' m; then false; fi
}

@test "owner_set: a subresource Apply entry does not count" {
    local obj='{"metadata":{"managedFields":[{"manager":"m","operation":"Apply","subresource":"status","fieldsV1":{"f:status":{}}}]}}'
    if managedfields_owner_set "$obj" m; then false; fi
}

@test "project: run-stage keeps every field Kaptain owns" {
    managedfields_project "$(fixture_json run-stage)" "$KAPTAIN"
    local p=$MANAGEDFIELDS_PROJECTED
    [ "$(yq -p=json -o=yaml '.spec.selector.matchLabels.app' <<<"$p")" = run-stage ]
    [ "$(yq -p=json -o=yaml '.spec.replicas' <<<"$p")" = 2 ]
    [ "$(yq -p=json -o=yaml '.spec.template.spec.containers[0].command[0]' <<<"$p")" = /kd/bin/deploy ]
    [ "$(yq -p=json -o=yaml '.spec.template.spec.volumes[1].secret.secretName' <<<"$p")" = run-stage-secret-def456 ]
    [ "$(yq -p=json -o=yaml '.metadata.labels."kaptain.org/version"' <<<"$p")" = 1.2.2 ]
    [ "$(yq -p=json -o=yaml '.metadata.resourceVersion' <<<"$p")" = 123456 ]
}

@test "project: run-stage leaves out everything Kaptain does not own" {
    managedfields_project "$(fixture_json run-stage)" "$KAPTAIN"
    local p=$MANAGEDFIELDS_PROJECTED
    local absent
    for absent in status managedFields creationTimestamp generation \
            deployment.kubernetes.io/revision progressDeadlineSeconds dnsPolicy \
            restartPolicy schedulerName terminationMessagePath defaultMode \
            '"serviceAccount"'; do
        [[ "$p" != *"$absent"* ]] || { echo "unexpected: $absent"; return 1; }
    done
}

@test "project: projecting the projection changes nothing" {
    # Anything in the first result outside the owner's set would be dropped
    # the second time, so a difference means the walk let something through.
    local live first again
    live=$(fixture_json run-stage)
    managedfields_project "$live" "$KAPTAIN"
    first=$MANAGEDFIELDS_PROJECTED
    managedfields_project "$(yq -p=json -o=json -I0 ".metadata.managedFields = $(yq -p=json -o=json -I0 '.metadata.managedFields' <<<"$live")" <<<"$first")" "$KAPTAIN"
    again=$MANAGEDFIELDS_PROJECTED
    [ "$(yq -p=json -o=json -I0 'sort_keys(..)' <<<"$again")" = "$(yq -p=json -o=json -I0 'sort_keys(..)' <<<"$first")" ]
}

@test "project: segment kinds beyond f: and a one-key k:" {
    managedfields_project "$(fixture_json edge)" owner
    [ "$MANAGEDFIELDS_PROJECTED" = '{"spec":{"template":{"spec":{"containers":[{"ports":[{"containerPort":8080,"protocol":"TCP"}],"name":"second","image":"second:1"}],"tolerations":[{"key":"k","operator":"Exists"}]}}},"metadata":{"finalizers":["b.example/y"],"name":"edge","namespace":"ns","resourceVersion":"9","uid":"u-1"},"apiVersion":"apps/v1","kind":"Deployment"}' ]
}

@test "project: only the merge keys the element's set lists go with it" {
    # An Apply set lists f:<key> for every key the applier sent; one it does
    # not list was defaulted by the server and is not the owner's.
    local obj='{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]},"spec":{"template":{"spec":{"containers":[{"name":"side","image":"s:1"},{"name":"main","image":"m:1"}]}}}}'
    managedfields_project "$obj" m
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"containers":[{"image":"m:1"}]'* ]]
    obj=${obj/'{"f:image":{}}'/'{"f:image":{},"f:name":{}}'}
    managedfields_project "$obj" m
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"containers":[{"image":"m:1","name":"main"}]'* ]]
}

@test "project: an unknown segment kind fails rather than guessing" {
    local obj='{"kind":"D","metadata":{"resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:spec":{"x:odd":{}}}}]},"spec":{}}'
    if managedfields_project "$obj" m; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"unknown fieldsV1 segment: x:odd"* ]]
}

@test "project: an owned field the live object lacks is left out and listed" {
    # The server drops zero values such as readOnly: false. Filling the gap
    # would send the parent's contents; leaving it out changes nothing.
    local obj='{"kind":"D","metadata":{"resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:spec":{"f:mounts":{"k:{\"path\":\"/d\"}":{".":{},"f:path":{},"f:readOnly":{}}}}}}]},"spec":{"mounts":[{"path":"/d"}]}}'
    managedfields_project "$obj" m
    [ "$(yq -p=json -o=json -I0 '.spec.mounts' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"path":"/d"}]' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:spec","f:mounts","k:{\"path\":\"/d\"}","f:readOnly"]]' ]
}

@test "project: an owned element gone from the live object is left out and listed" {
    local obj='{"kind":"D","metadata":{"resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{"k:{\"name\":\"gone\"}":{"f:name":{}},"k:{\"name\":\"here\"}":{"f:name":{}}}}}]},"c":[{"name":"x"},{"name":"here"}]}'
    managedfields_project "$obj" m
    [ "$(yq -p=json -o=json -I0 '.c' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"name":"here"}]' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:c","k:{\"name\":\"gone\"}"]]' ]
}

@test "project: a marker on a list keeps it a list" {
    local obj='{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:spec":{"f:ports":{".":{},"k:{\"containerPort\":80}":{".":{},"f:containerPort":{}}}}}}]},"spec":{"ports":[{"containerPort":79},{"containerPort":80}]}}'
    managedfields_project "$obj" m
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"spec":{"ports":[{"containerPort":80}]}'* ]]
}

project_m() {
    managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":'"$1"'}]},'"$2"'}' m
}

@test "project: an element matched twice fails rather than picking one" {
    # Duplicated env names happen; sending the first would quietly change
    # the effective value.
    if project_m '{"f:env":{"k:{\"name\":\"X\"}":{}}}' '"env":[{"name":"X","value":"a"},{"name":"Y"},{"name":"X","value":"b"}]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"owned element 2 times in the live object, not once"* ]]
}

@test "project: a set member matched twice fails too" {
    if project_m '{"f:f":{"v:\"a\"":{}}}' '"f":["a","a"]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"owned set member 2 times"* ]]
}

@test "project: a null inside a value owned whole is kept" {
    project_m '{"f:x":{}}' '"x":[1,null,2]'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"x":[1,null,2]'* ]]
}

@test "project: a key matches by type as well as value" {
    project_m '{"f:c":{"k:{\"p\":\"80\"}":{"f:p":{},"f:v":{}}}}' '"c":[{"p":80,"v":"int"},{"p":"80","v":"str"}]'
    [ "$(yq -p=json -o=json -I0 '.c | sort_keys(..)' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"p":"80","v":"str"}]' ]
}

@test "project: a positional element is refused" {
    if project_m '{"f:l":{"i:1":{}}}' '"l":["a","b"]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"positional list elements are not supported"* ]]
}

@test "project: nested keyed lists drop only their own padding" {
    project_m '{"f:a":{"k:{\"n\":\"o\"}":{"f:n":{},"f:in":{"k:{\"n\":\"i\"}":{"f:n":{},"f:x":{}}}}}}' \
        '"a":[{"n":"skip"},{"n":"o","in":[{"n":"z"},{"n":"i","x":[null,1]}]}]'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"a":[{"n":"o","in":[{"n":"i","x":[null,1]}]}]'* ]]
}

@test "owner_set: an entry with no set is refused" {
    if managedfields_owner_set '{"metadata":{"managedFields":[{"manager":"m","operation":"Apply"}]}}' m; then false; fi
}

@test "image_owner: managedFields that cannot be read return 1, not nobody" {
    local rc=0
    managedfields_image_owner 'not json [' containers main || rc=$?
    [ "$rc" -eq 1 ]
}

@test "owner_set: an empty set or one that is not a map is refused" {
    local f
    for f in '{}' '"str"' 'null'; do
        if managedfields_owner_set '{"metadata":{"managedFields":[{"manager":"m","operation":"Apply","fieldsV1":'"$f"'}]}}' m; then false; fi
    done
}

@test "project: an empty set fails rather than copying the object" {
    if project_m '{}' '"spec":{}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"the manager's entry holds no field set"* ]]
}

@test "project: an entry for another apiVersion fails" {
    if managedfields_project '{"apiVersion":"apps/v1","kind":"D","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","apiVersion":"apps/v1beta2","fieldsV1":{"f:spec":{}}}]},"spec":{}}' m; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"is for apps/v1beta2, the object was read as apps/v1"* ]]
}

@test "project: a null set member fails rather than vanishing" {
    if project_m '{"f:l":{"v:null":{}}}' '"l":[1,null]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"a null set member cannot be sent"* ]]
}

@test "project: yq's stderr on a success is not mixed into the body" {
    # A yq that warns, as some versions do on some inputs, then does its job.
    local bin="$BATS_TEST_TMPDIR/bin" real
    real=$(command -v yq)
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\necho "level=WARN msg=something" >&2\nexec %q "$@"\n' "$real" >"$bin/yq"
    chmod +x "$bin/yq"
    PATH="$bin:$PATH" project_m '{"f:x":{}}' '"x":1'
    [ "${MANAGEDFIELDS_PROJECTED:0:1}" = "{" ]
    [[ "$MANAGEDFIELDS_PROJECTED" != *"WARN"* ]]
}

# keelson_and_mf <other-manager> <other-operation> <other-time> <keelson-time> [<keelson-operation>]
# The image co-owned by keelson's entry (Apply unless given) and another
# manager's entry.
keelson_and_mf() {
    local img='"fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}'
    printf '[{"manager":"%s","operation":"%s","time":"%s",%s},{"manager":"keelson","operation":"%s","time":"%s",%s}]' \
        "$1" "$2" "$3" "$img" "${5:-Apply}" "$4" "$img"
}

@test "image_owner: another applier beats keelson's Apply, whichever is newer" {
    local old=2026-01-01T00:00:00Z new=2026-09-01T00:00:00Z mf
    for mf in "$(keelson_and_mf argocd Apply "$old" "$new")" "$(keelson_and_mf argocd Apply "$new" "$old")"; do
        managedfields_image_owner "$mf" containers main
        [ "$MANAGEDFIELDS_OWNER" = argocd ]
        [ "$MANAGEDFIELDS_OWNER_OPERATION" = Apply ]
    done
}

@test "image_owner: an Update owner beats keelson's Apply, whichever is newer" {
    local old=2026-01-01T00:00:00Z new=2026-09-01T00:00:00Z mf
    for mf in "$(keelson_and_mf helm Update "$old" "$new")" "$(keelson_and_mf helm Update "$new" "$old")"; do
        managedfields_image_owner "$mf" containers main
        [ "$MANAGEDFIELDS_OWNER" = helm ]
        [ "$MANAGEDFIELDS_OWNER_OPERATION" = Update ]
    done
}

@test "image_owner: another manager's Update beats keelson's Update, whichever is newer" {
    local old=2026-01-01T00:00:00Z new=2026-09-01T00:00:00Z mf
    for mf in "$(keelson_and_mf helm Update "$old" "$new" Update)" "$(keelson_and_mf helm Update "$new" "$old" Update)"; do
        managedfields_image_owner "$mf" containers main
        [ "$MANAGEDFIELDS_OWNER" = helm ]
        [ "$MANAGEDFIELDS_OWNER_OPERATION" = Update ]
    done
}

@test "image_owner: keelson's Apply still owns the image when nobody else does" {
    managedfields_image_owner '[{"manager":"keelson","operation":"Apply","time":"2026-01-01T00:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},
      {"manager":"keelson","operation":"Update","time":"2026-09-01T00:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = keelson ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = Apply ]
}

@test "owner_set: two Apply entries under the one manager are refused" {
    if managedfields_owner_set '{"metadata":{"managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:a":{}}},{"manager":"m","operation":"Apply","fieldsV1":{"f:b":{}}}]}}' m; then false; fi
}

@test "image_owner: the latest of several Update owners wins" {
    managedfields_image_owner '[
      {"manager":"old","operation":"Update","time":"2026-01-01T00:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},
      {"manager":"new","operation":"Update","time":"2026-02-01T00:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "new" ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = "Update" ]
}

@test "image_owner: input that is not a list returns 1" {
    local j rc
    for j in '{}' '"s"'; do
        rc=0
        managedfields_image_owner "$j" containers main || rc=$?
        [ "$rc" -eq 1 ]
    done
}

@test "project: field names yq would read as a pattern or a merge are refused" {
    local k
    for k in 'path*' 'a?' '<<'; do
        if project_m "{\"f:c\":{\"f:$k\":{}}}" "\"c\":{\"$k\":1,\"pathB\":2,\"ab\":3}"; then false; fi
        [[ "$MANAGEDFIELDS_PROJECTED" == *"cannot be handled exactly"* ]]
    done
}

@test "project: a merge key name yq would read as a pattern is refused" {
    if project_m '{"f:c":{"k:{\"n*\":\"x\"}":{"f:v":{}}}}' '"c":[{"nb":"x","v":1}]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"cannot be handled exactly"* ]]
}

@test "project: keyed or set segments on a live map are refused" {
    if project_m '{"f:c":{"k:{\"name\":\"x\"}":{"f:name":{}}}}' '"c":{"foo":{"name":"x"}}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"not in a list in the live object"* ]]
    if project_m '{"f:c":{"v:\"x\"":{}}}' '"c":{"k":"x"}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"not in a list in the live object"* ]]
}

@test "project: a marker on a live null is refused" {
    if project_m '{"f:c":{".":{}}}' '"c":null'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"not a map or a list"* ]]
}

@test "project: an object with no namespace gets none" {
    managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{}}}]},"c":1}' m
    [[ "$MANAGEDFIELDS_PROJECTED" != *'"namespace"'* ]]
}

@test "project: a map copied whole that holds a pattern-like key is refused" {
    # yq collapses such keys when the map passes through an object it builds.
    if project_m '{"f:spec":{"f:o":{}}}' '"spec":{"o":{"b":{"x":1},"*":{"y":2}}}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"holds a key that cannot be handled exactly: *"* ]]
}

@test "project: a merge key anywhere in the object is refused" {
    if project_m '{"f:c":{}}' '"c":{"<<":{"y":1},"x":2}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"cannot be handled exactly: <<"* ]]
}

@test "project: a live element named like a pattern does not match another name" {
    project_m '{"f:env":{"k:{\"name\":\"X\"}":{"f:name":{},"f:value":{}}}}' '"env":[{"name":"*","value":"wrong"}]'
    [[ "$MANAGEDFIELDS_PROJECTED" != *wrong* ]]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:env","k:{\"name\":\"X\"}"]]' ]
}

@test "project: a namespace named null is kept" {
    managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"null","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{}}}]},"c":1}' m
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"namespace":"null"'* ]]
}

@test "project: a subresource entry under the manager is not its set" {
    # Listed first, so taking the first entry by name would send status.
    managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","subresource":"status","fieldsV1":{"f:status":{}}},{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{}}}]},"c":1,"status":{"s":1}}' m
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"c":1'* ]]
    [[ "$MANAGEDFIELDS_PROJECTED" != *'"status"'* ]]
}

@test "owner_set: a manager name is matched exactly, not as a pattern" {
    if managedfields_owner_set '{"metadata":{"managedFields":[{"manager":"ab","operation":"Apply","fieldsV1":{"f:x":{}}}]}}' 'a*'; then false; fi
}

@test "project: the manager's entry is matched exactly, not as a pattern" {
    managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"ab","operation":"Apply","fieldsV1":{"f:x":{}}},{"manager":"a*","operation":"Apply","fieldsV1":{"f:y":{}}}]},"x":1,"y":2}' 'a*'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"y":2'* ]]
    [[ "$MANAGEDFIELDS_PROJECTED" != *'"x":1'* ]]
}

@test "project: a value holding U+0085 is refused, not folded" {
    if project_m '{"f:e":{}}' "$(printf '"e":"line1\xc2\x85line2"')"; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"U+0085 (NEL)"* ]]
}

@test "project: a map key \"[]\" is refused, not dropped" {
    if project_m '{"f:c":{"f:[]":{},"f:a":{}}}' '"c":{"a":1,"[]":5}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"cannot be handled exactly: []"* ]]
}

@test "image_owner: an owner's name holding a line break is refused" {
    local rc=0
    managedfields_image_owner '[{"manager":"a\nApply|9|evil","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main || rc=$?
    [ "$rc" -eq 1 ]
}

@test "image_owner: an owner's name holding a carriage return is refused" {
    local rc=0
    managedfields_image_owner '[{"manager":"a\rb","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main || rc=$?
    [ "$rc" -eq 1 ]
}

@test "image_owner: an owner with no name is refused, not passed over" {
    local rc=0
    managedfields_image_owner '[{"manager":"","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},{"manager":"u","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main || rc=$?
    [ "$rc" -eq 1 ]
}

@test "image_owner: an owner's name holding a NUL is refused, not shortened" {
    # bash drops NUL from a capture: "\u0000" would come back empty and hand
    # the image to the lesser owner.
    local img='{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}' n rc
    for n in 'a\u0000b' '\u0000'; do
        rc=0
        managedfields_image_owner '[{"manager":"'"$n"'","operation":"Apply","time":"2026-01-02T00:00:00Z","fieldsV1":'"$img"'},{"manager":"lesser","operation":"Update","time":"2026-01-03T00:00:00Z","fieldsV1":'"$img"'}]' containers main || rc=$?
        [ "$rc" -eq 1 ] || { echo "$n: rc=$rc owner=$MANAGEDFIELDS_OWNER"; return 1; }
    done
}

@test "project: a set member with fields beneath it is refused, not walked into" {
    local set
    for set in '{"f:s":{"v:{\"a\":1,\"b\":2}":{"f:a":{}}}}' '{"f:s":{"v:{\"a\":1,\"b\":2}":{".":{}}}}'; do
        if project_m "$set" '"s":[{"a":1,"b":2},{"a":3}]'; then echo "$set: $MANAGEDFIELDS_PROJECTED"; return 1; fi
        [[ "$MANAGEDFIELDS_PROJECTED" == *"owned set member has fields beneath it"* ]]
    done
}

@test "image_owner: an owner whose time holds a line break or | is refused" {
    # Either would shift where the name is split off the line.
    local img='{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}' t rc
    for t in '2026-01-01T00:00:00Z\nimpostor' '2026|x'; do
        rc=0
        managedfields_image_owner '[{"manager":"real","operation":"Apply","time":"'"$t"'","fieldsV1":'"$img"'}]' containers main || rc=$?
        [ "$rc" -eq 1 ] || { echo "$t: rc=$rc owner=$MANAGEDFIELDS_OWNER"; return 1; }
    done
}

@test "project: a merge key does not name an element that is a list" {
    project_m '{"f:l":{"k:{\"1\":\"t\"}":{".":{}}}}' '"l":[["s","t"]]'
    [[ "$MANAGEDFIELDS_PROJECTED" != *'"t"'* ]]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:l","k:{\"1\":\"t\"}"]]' ]
}

@test "image_owner: a manager name ending in | keeps it" {
    local img='{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}'
    managedfields_image_owner '[{"manager":"argo|","operation":"Apply","time":"2026-01-02T00:00:00Z","fieldsV1":'"$img"'},{"manager":"argo","operation":"Apply","fieldsV1":{"f:spec":{"f:replicas":{}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "argo|" ]
    managedfields_image_owner '[{"manager":"|","operation":"Apply","time":"2026-01-02T00:00:00Z","fieldsV1":'"$img"'},{"manager":"helm","operation":"Update","time":"2026-01-03T00:00:00Z","fieldsV1":'"$img"'}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "|" ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = "Apply" ]
}

@test "image_owner: a | in a name does not leak into the time compared" {
    # Equal times keep the earlier entry; were the time read as "<time>|a",
    # the later "<time>|z" would win.
    local img='{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}'
    managedfields_image_owner '[{"manager":"a|q","operation":"Update","time":"2026-01-02T00:00:00Z","fieldsV1":'"$img"'},{"manager":"z|q","operation":"Update","time":"2026-01-02T00:00:00Z","fieldsV1":'"$img"'}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "a|q" ]
}

@test "image_owner: a | in a manager name comes through whole" {
    managedfields_image_owner '[{"manager":"m|x","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "m|x" ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = "Update" ]
}

@test "image_owner: an odd name on a manager that does not own the image is no bar" {
    managedfields_image_owner '[{"manager":"a\nb","operation":"Update","fieldsV1":{"f:metadata":{}}},{"manager":"helm","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = "helm" ]
}

@test "project: a marker with fields beneath it is refused" {
    if project_m '{"f:c":{".":{"f:x":{}}}}' '"c":{"x":1,"y":2}'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"owned marker has fields beneath it"* ]]
}

@test "project: a set node that is not a map is refused, not dropped" {
    local bad
    for bad in null 1 '[]'; do
        if project_m '{"f:c":{"f:x":'"$bad"',"f:y":{}}}' '"c":{"x":1,"y":2}'; then false; fi
        [[ "$MANAGEDFIELDS_PROJECTED" == *"holds something other than maps"* ]]
    done
}

@test "project: a key or member that is not canonical JSON is refused" {
    local seg
    for seg in 'k:{name: a}' 'k:{\"name\":\"\\x41\"}' "k:{'name':'a'}"; do
        if project_m '{"f:env":{"'"$seg"'":{"f:name":{}}}}' '"env":[{"name":"a"},{"name":"A"}]'; then false; fi
        [[ "$MANAGEDFIELDS_PROJECTED" == *"not canonical JSON"* ]] || { echo "$seg: $MANAGEDFIELDS_PROJECTED"; return 1; }
    done
    if project_m '{"f:f":{"v: \"b\"":{}}}' '"f":["b"]'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"not canonical JSON"* ]]
}

@test "project: keys and members as the server writes them, with Go's HTML escaping, match" {
    project_m '{"f:l":{"k:{\"name\":\"a\\u0026b\"}":{"f:name":{},"f:x":{}}}}' '"l":[{"name":"a&b","x":1}]'
    [ "$(yq -p=json -o=json -I0 '.l | sort_keys(..)' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"name":"a&b","x":1}]' ]
    project_m '{"f:l":{"v:\"\\u003c\"":{}}}' '"l":["<","x"]'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"l":["<"]'* ]]
}

@test "project: a set member that is the string null is kept" {
    project_m '{"f:l":{"v:\"null\"":{}}}' '"l":["null","x"]'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"l":["null"]'* ]]
}

@test "project: a map key holding U+0085 is refused" {
    if project_m '{"f:c":{}}' "$(printf '"c":{"a\xc2\x85b":1}')"; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"cannot be handled exactly"* ]]
}

@test "project: an object with no resourceVersion is refused" {
    if managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","namespace":"n","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{}}}]},"c":1}' m; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"carries no resourceVersion"* ]]
}

@test "project: a set member or merge key that is not valid YAML still matches" {
    # from_json reads YAML, and is evaluated for branches a segment does not
    # take: "x: " parsed as a k: payload would fail the walk.
    project_m '{"f:l":{"v:\"x: \"":{}}}' '"l":["z","x: "]'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"l":["x: "]'* ]]
    project_m '{"f:l":{"k:{\"name\":\"x: \"}":{"f:name":{},"f:v":{}}}}' '"l":[{"name":"z"},{"name":"x: ","v":1}]'
    [ "$(yq -p=json -o=json -I0 '.l | sort_keys(..)' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"name":"x: ","v":1}]' ]
}

@test "project: backspace and form feed match written either way" {
    # Older Go writes \u0008 and \u000c, newer writes \b and \f.
    local set want
    for set in '"v:\"a\\bb\""' '"v:\"a\\u0008b\""' '"v:\"a\\fb\""' '"v:\"a\\u000cb\""'; do
        project_m "{\"f:l\":{$set:{}}}" '"l":["a\bb","a\fb","x"]' || { echo "$set: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$(yq -p=json '.l | length' <<<"$MANAGEDFIELDS_PROJECTED")" -eq 1 ]
        # The member the set names, not the other control character.
        case "$set" in *'\\b'*|*0008*) want=$'a\bb' ;; *) want=$'a\fb' ;; esac
        [ "$(yq -p=json '.l[0] | @base64' <<<"$MANAGEDFIELDS_PROJECTED")" = "$(printf '%s' "$want" | base64)" ] \
            || { echo "$set: $MANAGEDFIELDS_PROJECTED"; return 1; }
    done
    project_m '{"f:l":{"k:{\"name\":\"a\\fb\"}":{"f:v":{}}}}' '"l":[{"name":"a\fb","v":1}]'
    [ "$(yq -p=json '.l[0].v' <<<"$MANAGEDFIELDS_PROJECTED")" -eq 1 ]
}

@test "project: an apiVersion is compared exactly, not as a pattern" {
    if managedfields_project '{"apiVersion":"apps/v1*","kind":"D","metadata":{"name":"a","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","apiVersion":"apps/v1beta2","fieldsV1":{"f:c":{}}}]},"c":1}' m; then
        echo "$MANAGEDFIELDS_PROJECTED"; return 1
    fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"the manager's entry is for apps/v1beta2"* ]]
}

@test "project: a marker in the middle of a leaf is refused even when the leaf ends in one" {
    local set
    for set in '{"f:spec":{".":{"f:template":{".":{}}},"f:replicas":{}}}' \
            '{"f:spec":{"f:l":{".":{"k:{\"name\":\"b\"}":{".":{}}},"k:{\"name\":\"a\"}":{".":{},"f:name":{}}}}}'; do
        if project_m "$set" '"spec":{"replicas":2,"template":{"x":1},"l":[{"name":"a"},{"name":"b"}]}'; then
            echo "$set: $MANAGEDFIELDS_PROJECTED"; return 1
        fi
        [[ "$MANAGEDFIELDS_PROJECTED" == *"owned marker has fields beneath it"* ]]
    done
}

@test "image_owner: an owner holding the whole list owns every image in it" {
    # Argo Rollouts before v1.9 leaves containers atomic: f:containers alone.
    managedfields_image_owner '[{"manager":"argocd","operation":"Apply","time":"2026-01-01T00:00:00Z","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = argocd ]
    [ "$MANAGEDFIELDS_OWNER_OPERATION" = Apply ]
    managedfields_image_owner '[{"manager":"cj","operation":"Update","fieldsV1":{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}}}}]' containers main
    [ "$MANAGEDFIELDS_OWNER" = cj ]
    managedfields_image_owner '[{"manager":"v","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"vol\"}":{"f:image":{}}}}}}}}]' imageVolumes vol
    [ "$MANAGEDFIELDS_OWNER" = v ]
    # A field elsewhere, or a node with things beneath it, is not the image.
    managedfields_image_owner '[{"manager":"s","operation":"Apply","fieldsV1":{"f:spec":{"f:replicas":{},"f:template":{"f:spec":{"f:dnsPolicy":{}}}}}}]' containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
    managedfields_image_owner '[{"manager":"n","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:name":{}}}}}}}}]' containers main
    [ -z "$MANAGEDFIELDS_OWNER" ]
}

@test "image_owner: a container name the key cannot carry as written is refused, not read as unowned" {
    local n rc
    for n in 'a<b' 'a>b' 'a&b' 'a"b' 'a\b' 'a*' 'a?' $'a\tb' $'a\x01b' $'a\xe2\x80\xa8b' $'a\xe2\x80\xa9b'; do
        rc=0
        managedfields_image_owner '[{"manager":"m","operation":"Apply","fieldsV1":{}}]' containers "$n" || rc=$?
        [ "$rc" -eq 1 ] || { echo "$n: rc=$rc"; return 1; }
    done
}

@test "project: markers are laid down shallowest first whatever order the set lists them in" {
    # The "." after a child marker: laid down in the set's order, the
    # parent's {} would wipe the child's.
    project_m '{"f:template":{"f:metadata":{"f:labels":{".":{}}},".":{}}}' '"template":{"metadata":{"labels":{"a":"b"}}}'
    [[ "$MANAGEDFIELDS_PROJECTED" == *'"template":{"metadata":{"labels":{}}}'* ]]
}

@test "project: an owned subtree the live object lacks goes leaf by leaf, and a set member as itself" {
    # Each gone leaf reached through missing fields lists its own path, so a
    # metadata {} sent from the same missing node is not dropped with it.
    project_m '{"f:c":{"f:sc":{"f:ro":{},"f:u":{}},"f:x":{}},"f:fin":{"v:\"a\"":{},"v:\"b\"":{}}}' '"c":{"x":1},"fin":["a"]'
    [ "$(yq -p=json -o=json -I0 '[.c, .fin]' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"x":1},["a"]]' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:c","f:sc","f:ro"],["f:c","f:sc","f:u"],["f:fin","v:\"b\""]]' ]
}

@test "project: a set member whose live keys are in another order is sent, not omitted" {
    # The server writes v: with sorted keys; the live object keeps its own
    # order, nested maps included. Left out, the real apply would prune it.
    project_m '{"f:s":{"v:{\"a\":1,\"b\":{\"c\":1,\"d\":2}}":{}}}' '"s":[{"b":{"d":2,"c":1},"a":1},{"a":3}]'
    [ "$(yq -p=json -o=json -I0 '.s | sort_keys(..)' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"a":1,"b":{"c":1,"d":2}}]' ]
    [ "$MANAGEDFIELDS_OMITTED" = "[]" ]
}

@test "project: nothing missing means nothing listed" {
    project_m '{"f:c":{}}' '"c":1'
    [ "$MANAGEDFIELDS_OMITTED" = "[]" ]
}

@test "project: a field under a live value that is not a map is still refused" {
    if project_m '{"f:c":{"f:x":{}}}' '"c":5'; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"owned field's parent is not a map in the live object"* ]]
}

@test "set_without: the omitted paths go, and maps they leave empty with them" {
    managedfields_set_without '{"f:c":{"f:sc":{"f:ro":{}},"f:x":{}},"f:l":{"k:{\"name\":\"b\"}":{".":{},"f:name":{}}}}' \
        '[["f:c","f:sc","f:ro"],["f:l","k:{\"name\":\"b\"}"]]'
    [ "$MANAGEDFIELDS_SET_EXPECTED" = '{"f:c":{"f:x":{}}}' ]
    # An owned leaf that is itself {} is not an emptied map: it stays.
    managedfields_set_without '{"f:a":{},"f:b":{"f:c":{}}}' '[["f:b","f:c"]]'
    [ "$MANAGEDFIELDS_SET_EXPECTED" = '{"f:a":{}}' ]
}

@test "set_without: an omitted list too big for one environment string is still read" {
    local big
    big=$(head -c 140000 /dev/zero | tr '\0' x)
    managedfields_set_without '{"f:a":{},"f:metadata":{"f:annotations":{"f:'"$big"'":{}}}}' '[["f:metadata","f:annotations","f:'"$big"'"]]'
    [ "$MANAGEDFIELDS_SET_EXPECTED" = '{"f:a":{}}' ]
}

@test "project: an owned {} at metadata annotations or labels is sent as {}, never copied or left out" {
    # ObjectMeta's maps merge key by key: {} leaves kubectl's restartedAt
    # where it is, and the owner's set comes back as it was.
    local name
    for name in annotations labels; do
        project_m "{\"f:spec\":{\"f:template\":{\"f:metadata\":{\"f:$name\":{}}}}}" "\"spec\":{\"template\":{\"metadata\":{\"$name\":{\"kubectl.kubernetes.io/restartedAt\":\"x\"}}}}"
        [ "$(yq -p=json -o=json -I0 ".spec.template.metadata.$name" <<<"$MANAGEDFIELDS_PROJECTED")" = '{}' ] || { echo "$name: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
        # Absent live too: still {}, still not left out.
        project_m "{\"f:spec\":{\"f:template\":{\"f:metadata\":{\"f:$name\":{}}}}}" '"spec":{"template":{"spec":{}}}'
        [ "$(yq -p=json -o=json -I0 ".spec.template.metadata.$name" <<<"$MANAGEDFIELDS_PROJECTED")" = '{}' ] || { echo "$name absent: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
    done
    # The object's own metadata as well.
    project_m '{"f:metadata":{"f:labels":{}}}' '"spec":{}'
    [ "$(yq -p=json -o=json -I0 '.metadata.labels' <<<"$MANAGEDFIELDS_PROJECTED")" = '{}' ]
}

@test "project: any other owned {} still copies the live value" {
    project_m '{"f:spec":{"f:template":{"f:spec":{"f:nodeSelector":{}}}}}' '"spec":{"template":{"spec":{"nodeSelector":{"a":"b"}}}}'
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.nodeSelector' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"a":"b"}' ]
}

# --- kubectl's client-side-apply migration ---

csa_entry() {
    printf '{"manager":"%s","operation":"%s"%s,"fieldsV1":{"f:metadata":{"f:annotations":{".":{},"f:kubectl.kubernetes.io/last-applied-configuration":{}}}}}' "$1" "$2" "${3:+,\"subresource\":\"$3\"}"
}

@test "csa_holders: an Update entry owning last-applied-configuration is named" {
    managedfields_csa_holders '{"metadata":{"managedFields":['"$(csa_entry kubectl-client-side-apply Update)"','"$(csa_entry 'a*' Update)"']}}'
    # In entry order, each once.
    [ "$MANAGEDFIELDS_CSA_HOLDERS" = "'kubectl-client-side-apply', 'a*'" ]
}

@test "csa_holders: an Apply entry, a subresource entry or no entry is not one" {
    local rc obj
    for obj in '{"metadata":{"managedFields":['"$(csa_entry argocd Apply)"']}}' \
            '{"metadata":{"managedFields":['"$(csa_entry kcm Update status)"']}}' \
            '{"metadata":{}}'; do
        rc=0
        managedfields_csa_holders "$obj" || rc=$?
        [ "$rc" -eq 1 ] || { echo "$obj: rc=$rc"; return 1; }
        [ -z "$MANAGEDFIELDS_CSA_HOLDERS" ]
    done
}

@test "csa_holders: an object that cannot be read returns 2" {
    local rc=0
    managedfields_csa_holders 'not json' || rc=$?
    [ "$rc" -eq 2 ]
}

# --- merge keys: only those the element's own set lists are sent ---

# ports_obj <port-set-json>: a Deployment whose container main has one port
# 80/TCP live, and whose owner m holds main with the given port set.
ports_obj() {
    printf '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","apiVersion":"apps/v1","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\\"name\\":\\"main\\"}":{".":{},"f:name":{},"f:ports":{"k:{\\"containerPort\\":80,\\"protocol\\":\\"TCP\\"}":%s}}}}}}}}]},"spec":{"template":{"spec":{"containers":[{"name":"main","image":"i","ports":[{"containerPort":80,"protocol":"TCP"}]}]}}}}' "$1"
}

@test "project: a merge key the server defaulted is not sent" {
    # The owner applied {containerPort: 80}; the server added protocol and
    # the set lists only f:containerPort (checked on a cluster, 2026-10-18).
    managedfields_project "$(ports_obj '{".":{},"f:containerPort":{}}')" m
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers[0].ports' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"containerPort":80}]' ]
}

@test "project: a merge key the set lists is sent" {
    managedfields_project "$(ports_obj '{".":{},"f:containerPort":{},"f:protocol":{}}')" m
    [ "$(yq -p=json -o=json -I0 '.spec.template.spec.containers[0].ports' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"containerPort":80,"protocol":"TCP"}]' ]
}

@test "project: an element's listed name goes with it, marker or not" {
    project_m '{"f:env":{"k:{\"name\":\"A\"}":{"f:name":{},"f:value":{}}}}' '"env":[{"name":"A","value":"1"}]'
    [ "$(yq -p=json -o=json -I0 '.env | sort_keys(..)' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"name":"A","value":"1"}]' ]
    project_m '{"f:env":{"k:{\"name\":\"A\"}":{".":{},"f:name":{}}}}' '"env":[{"name":"A","value":"1"}]'
    [ "$(yq -p=json -o=json -I0 '.env' <<<"$MANAGEDFIELDS_PROJECTED")" = '[{"name":"A"}]' ]
}

@test "project: the body carries the read's uid, and an object without one is refused" {
    project_m '{"f:c":{}}' '"c":1'
    [ "$(yq -p=json '.metadata.uid' <<<"$MANAGEDFIELDS_PROJECTED")" = u-1 ]
    if managedfields_project '{"apiVersion":"v1","kind":"D","metadata":{"name":"a","resourceVersion":"1","managedFields":[{"manager":"m","operation":"Apply","fieldsV1":{"f:c":{}}}]},"c":1}' m; then false; fi
    [[ "$MANAGEDFIELDS_PROJECTED" == *"carries no uid"* ]]
}

@test "project: a metadata {} beside other gone fields under a missing metadata is kept out of omitted" {
    project_m '{"f:spec":{"f:jobTemplate":{"f:metadata":{"f:annotations":{},"f:creationTimestamp":{}},"f:spec":{"f:x":{}}}}}' '"spec":{"jobTemplate":{"spec":{"x":1}}}'
    [ "$(yq -p=json -o=json -I0 '.spec.jobTemplate.metadata' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"annotations":{}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:spec","f:jobTemplate","f:metadata","f:creationTimestamp"]]' ]
    managedfields_set_without '{"f:spec":{"f:jobTemplate":{"f:metadata":{"f:annotations":{},"f:creationTimestamp":{}},"f:spec":{"f:x":{}}}}}' "$MANAGEDFIELDS_OMITTED"
    [ "$MANAGEDFIELDS_SET_EXPECTED" = '{"f:spec":{"f:jobTemplate":{"f:metadata":{"f:annotations":{}},"f:spec":{"f:x":{}}}}}' ]
}

@test "project: a gone element is still omitted whole" {
    project_m '{"f:l":{"k:{\"name\":\"gone\"}":{".":{},"f:name":{},"f:v":{}}}}' '"l":[{"name":"here","v":1}]'
    [ "$MANAGEDFIELDS_OMITTED" = '[["f:l","k:{\"name\":\"gone\"}"]]' ]
}

@test "list_held_whole: an ancestor of the list held as {} counts" {
    managedfields_list_held_whole '[{"manager":"a","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{}}}}]' containers
    managedfields_list_held_whole '[{"manager":"a","operation":"Apply","fieldsV1":{"f:spec":{}}}]' containers
}

@test "list_held_whole: managedFields that are not a list or not JSON return 2" {
    local j rc
    for j in '{}' '"s"' '[{'; do
        rc=0
        managedfields_list_held_whole "$j" containers || rc=$?
        [ "$rc" -eq 2 ]
    done
}

@test "project: the metadata {} rule holds only at ObjectMeta positions" {
    # Inside a list element (or any other field), a map named
    # metadata.labels may be atomic: copied live like any {} leaf.
    project_m '{"f:l":{"k:{\"name\":\"X\"}":{"f:name":{},"f:metadata":{"f:labels":{}}}}}' '"l":[{"name":"X","metadata":{"labels":{"a":"b"}}}]'
    [ "$(yq -p=json -o=json -I0 '.l[0].metadata.labels' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"a":"b"}' ]
    project_m '{"f:spec":{"f:x":{"f:metadata":{"f:labels":{}}}}}' '"spec":{"x":{"metadata":{"labels":{"r":"1"}}}}'
    [ "$(yq -p=json -o=json -I0 '.spec.x.metadata.labels' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"r":"1"}' ]
    # Each real position still sends {}.
    local path set live
    for path in 'spec.template' 'spec.jobTemplate' 'spec.jobTemplate.spec.template'; do
        set=$(P=$path yq -n -o=json -I0 '{} | setpath((strenv(P) | split(".") | map("f:" + .)) + ["f:metadata", "f:labels"]; {})')
        live=$(P=$path yq -n -o=json -I0 '{} | setpath((strenv(P) | split(".")) + ["metadata", "labels"]; {"r": "1"})')
        project_m "$set" "${live:1:${#live}-2}"
        [ "$(yq -p=json -o=json -I0 ".$path.metadata.labels" <<<"$MANAGEDFIELDS_PROJECTED")" = '{}' ] \
            || { echo "$path: $MANAGEDFIELDS_PROJECTED"; return 1; }
    done
    project_m '{"f:metadata":{"f:labels":{}}}' '"x":1'
    [ "$(yq -p=json -o=json -I0 '.metadata.labels' <<<"$MANAGEDFIELDS_PROJECTED")" = '{}' ]
}

# project_k <apiVersion> <kind> <set-json> <live-spec-json>: project_m on an
# object of the given type, with the given spec.
project_k() {
    managedfields_project '{"apiVersion":"'"$1"'","kind":"'"$2"'","metadata":{"name":"a","namespace":"n","resourceVersion":"1","uid":"u-1","managedFields":[{"manager":"m","operation":"Apply","apiVersion":"'"$1"'","fieldsV1":'"$3"'}]},"spec":'"$4"'}' m
}

@test "project: an owned {} at a Deployment's strategy is sent as {}, the server's defaults left live" {
    project_k apps/v1 Deployment '{"f:spec":{"f:replicas":{},"f:strategy":{}}}' '{"replicas":2,"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"replicas":2,"strategy":{}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
    # Absent live too: still {}, still not left out.
    project_k apps/v1 Deployment '{"f:spec":{"f:replicas":{},"f:strategy":{}}}' '{"replicas":2}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"replicas":2,"strategy":{}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
}

@test "project: an owned {} at a StatefulSet's or DaemonSet's updateStrategy is sent as {}" {
    local kind
    for kind in StatefulSet DaemonSet; do
        project_k apps/v1 "$kind" '{"f:spec":{"f:updateStrategy":{}}}' '{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":0}}}'
        [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"updateStrategy":{}}' ] || { echo "$kind: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ] || { echo "$kind: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "project: an owned {} at a Deployment's strategy.rollingUpdate is sent as {}, the server's defaults left live" {
    # As the server records strategy: {type: RollingUpdate, rollingUpdate: {}}.
    project_k apps/v1 Deployment '{"f:spec":{"f:strategy":{"f:type":{},"f:rollingUpdate":{}}}}' '{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"strategy":{"type":"RollingUpdate","rollingUpdate":{}}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
}

@test "project: an owned {} at a Deployment's strategy.rollingUpdate absent live is left out" {
    # Edited to Recreate since: validation forbids a rollingUpdate beside it.
    project_k apps/v1 Deployment '{"f:spec":{"f:strategy":{"f:type":{},"f:rollingUpdate":{}}}}' '{"strategy":{"type":"Recreate"}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"strategy":{"type":"Recreate"}}' ]
    [ "$(yq -p=json -o=json -I0 '.' <<<"$MANAGEDFIELDS_OMITTED")" = '[["f:spec","f:strategy","f:rollingUpdate"]]' ]
    # With the strategy around it gone too.
    project_k apps/v1 Deployment '{"f:spec":{"f:replicas":{},"f:strategy":{"f:rollingUpdate":{}}}}' '{"replicas":2}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"replicas":2}' ]
    [ "$(yq -p=json -o=json -I0 '.' <<<"$MANAGEDFIELDS_OMITTED")" = '[["f:spec","f:strategy","f:rollingUpdate"]]' ]
}

@test "project: an owned {} at a StatefulSet's or DaemonSet's updateStrategy.rollingUpdate is sent as {}" {
    local kind ru
    for kind in StatefulSet DaemonSet; do
        ru='{"partition":0}'
        [ "$kind" = DaemonSet ] && ru='{"maxSurge":0,"maxUnavailable":1}'
        project_k apps/v1 "$kind" '{"f:spec":{"f:updateStrategy":{"f:rollingUpdate":{}}}}' '{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":'"$ru"'}}'
        [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"updateStrategy":{"rollingUpdate":{}}}' ] || { echo "$kind: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ] || { echo "$kind: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "project: an owned {} at a StatefulSet's or DaemonSet's updateStrategy.rollingUpdate absent live is left out" {
    local kind
    for kind in StatefulSet DaemonSet; do
        project_k apps/v1 "$kind" '{"f:spec":{"f:updateStrategy":{"f:type":{},"f:rollingUpdate":{}}}}' '{"updateStrategy":{"type":"OnDelete"}}'
        [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"updateStrategy":{"type":"OnDelete"}}' ] || { echo "$kind: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$(yq -p=json -o=json -I0 '.' <<<"$MANAGEDFIELDS_OMITTED")" = '[["f:spec","f:updateStrategy","f:rollingUpdate"]]' ] || { echo "$kind: $MANAGEDFIELDS_OMITTED"; return 1; }
        project_k apps/v1 "$kind" '{"f:spec":{"f:replicas":{},"f:updateStrategy":{"f:rollingUpdate":{}}}}' '{"replicas":2}'
        [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"replicas":2}' ] || { echo "$kind absent: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$(yq -p=json -o=json -I0 '.' <<<"$MANAGEDFIELDS_OMITTED")" = '[["f:spec","f:updateStrategy","f:rollingUpdate"]]' ] || { echo "$kind absent: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "project: an owned {} at a StatefulSet's persistentVolumeClaimRetentionPolicy is sent as {}" {
    project_k apps/v1 StatefulSet '{"f:spec":{"f:persistentVolumeClaimRetentionPolicy":{}}}' '{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"Retain","whenScaled":"Retain"}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"persistentVolumeClaimRetentionPolicy":{}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
    project_k apps/v1 StatefulSet '{"f:spec":{"f:replicas":{},"f:persistentVolumeClaimRetentionPolicy":{}}}' '{"replicas":2}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"replicas":2,"persistentVolumeClaimRetentionPolicy":{}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
}

@test "project: any other owned {} on those kinds still copies the live value" {
    project_k apps/v1 Deployment '{"f:spec":{"f:selector":{}}}' '{"selector":{"matchLabels":{"app":"a"}}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"selector":{"matchLabels":{"app":"a"}}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
    project_k apps/v1 StatefulSet '{"f:spec":{"f:ordinals":{}}}' '{"ordinals":{"start":3}}'
    [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = '{"ordinals":{"start":3}}' ]
    [ "$MANAGEDFIELDS_OMITTED" = '[]' ]
}

@test "project: the struct {} rule holds only for its own kind, path and apiVersion" {
    # Each of these copies the live value: the field on another kind, the
    # name below the top-level spec or at another depth, a field inside the
    # struct, a Rollout (whose strategy the server does not default), and a
    # kind of that name in another group.
    local row api kind set live
    for row in \
            'apps/v1|Deployment|{"f:spec":{"f:updateStrategy":{}}}|{"updateStrategy":{"type":"x"}}' \
            'apps/v1|StatefulSet|{"f:spec":{"f:strategy":{}}}|{"strategy":{"type":"x"}}' \
            'apps/v1|DaemonSet|{"f:spec":{"f:strategy":{}}}|{"strategy":{"type":"x"}}' \
            'apps/v1|Deployment|{"f:spec":{"f:template":{"f:strategy":{}}}}|{"template":{"strategy":{"type":"x"}}}' \
            'apps/v1|Deployment|{"f:spec":{"f:strategy":{"f:rollingUpdate":{"f:maxSurge":{}}}}}|{"strategy":{"rollingUpdate":{"maxSurge":1}}}' \
            'apps/v1|Deployment|{"f:spec":{"f:strategy":{"f:type":{}}}}|{"strategy":{"type":"x"}}' \
            'apps/v1|Deployment|{"f:spec":{"f:persistentVolumeClaimRetentionPolicy":{}}}|{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"x"}}' \
            'apps/v1|DaemonSet|{"f:spec":{"f:persistentVolumeClaimRetentionPolicy":{}}}|{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"x"}}' \
            'apps/v1|Deployment|{"f:spec":{"f:updateStrategy":{"f:rollingUpdate":{}}}}|{"updateStrategy":{"rollingUpdate":{"a":1}}}' \
            'apps/v1|StatefulSet|{"f:spec":{"f:strategy":{"f:rollingUpdate":{}}}}|{"strategy":{"rollingUpdate":{"a":1}}}' \
            'apps/v1|DaemonSet|{"f:spec":{"f:strategy":{"f:rollingUpdate":{}}}}|{"strategy":{"rollingUpdate":{"a":1}}}' \
            'apps/v1|Deployment|{"f:spec":{"f:rollingUpdate":{}}}|{"rollingUpdate":{"a":1}}' \
            'apps/v1|StatefulSet|{"f:spec":{"f:rollingUpdate":{}}}|{"rollingUpdate":{"a":1}}' \
            'apps/v1|Deployment|{"f:spec":{"f:template":{"f:strategy":{"f:rollingUpdate":{}}}}}|{"template":{"strategy":{"rollingUpdate":{"a":1}}}}' \
            'apps/v1|StatefulSet|{"f:spec":{"f:updateStrategy":{"f:rollingUpdate":{"f:x":{}}}}}|{"updateStrategy":{"rollingUpdate":{"x":{"a":1}}}}' \
            'apps/v1|StatefulSet|{"f:spec":{"f:template":{"f:persistentVolumeClaimRetentionPolicy":{}}}}|{"template":{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"x"}}}' \
            'argoproj.io/v1alpha1|Rollout|{"f:spec":{"f:strategy":{"f:rollingUpdate":{}}}}|{"strategy":{"rollingUpdate":{"a":1}}}' \
            'example.com/v1|Deployment|{"f:spec":{"f:strategy":{"f:rollingUpdate":{}}}}|{"strategy":{"rollingUpdate":{"a":1}}}' \
            'example.com/v1|DaemonSet|{"f:spec":{"f:updateStrategy":{"f:rollingUpdate":{}}}}|{"updateStrategy":{"rollingUpdate":{"a":1}}}' \
            'example.com/v1|StatefulSet|{"f:spec":{"f:persistentVolumeClaimRetentionPolicy":{}}}|{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"x"}}' \
            'argoproj.io/v1alpha1|Rollout|{"f:spec":{"f:strategy":{}}}|{"strategy":{"type":"x"}}' \
            'example.com/v1|Deployment|{"f:spec":{"f:strategy":{}}}|{"strategy":{"type":"x"}}' \
            'example.com/v1|StatefulSet|{"f:spec":{"f:updateStrategy":{}}}|{"updateStrategy":{"type":"x"}}'; do
        IFS='|' read -r api kind set live <<<"$row"
        project_k "$api" "$kind" "$set" "$live"
        [ "$(yq -p=json -o=json -I0 '.spec' <<<"$MANAGEDFIELDS_PROJECTED")" = "$live" ] || { echo "$row: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ] || { echo "$row: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

# pod_k <apiVersion> <kind> <pod spec path> <set-json> <live-json>: project_k
# with the set and the live value placed at the given path (spec.x.y).
pod_k() {
    local set live
    set=$(P=$3 S=$4 yq -n -o=json -I0 '{} | setpath(strenv(P) | split(".") | map("f:" + .); strenv(S) | from_json)')
    live=$(P=$3 S=$5 yq -n -o=json -I0 '{} | setpath(strenv(P) | split(".") | .[1:]; strenv(S) | from_json)')
    project_k "$1" "$2" "$set" "$live"
}

# pod_at <path>: the projected value at the path, keys sorted.
pod_at() {
    yq -p=json -o=json -I0 ".$1 | sort_keys(..)" <<<"$MANAGEDFIELDS_PROJECTED"
}

@test "project: an owned {} at a container's resources or securityContext, or the pod's securityContext, is sent as {}" {
    # As a Helm chart renders them, then filled by a mutating webhook: {}
    # leaves the webhook's values live and the owner's set as it was.
    local set live want row api kind path
    set='{"f:securityContext":{},"f:containers":{"k:{\"name\":\"app\"}":{".":{},"f:name":{},"f:image":{},"f:resources":{},"f:securityContext":{}}},"f:initContainers":{"k:{\"name\":\"init\"}":{".":{},"f:name":{},"f:resources":{},"f:securityContext":{}}}}'
    live='{"securityContext":{"fsGroup":2000},"containers":[{"name":"side","image":"s","resources":{"limits":{"cpu":"1"}}},{"name":"app","image":"i","resources":{"limits":{"cpu":"200m"}},"securityContext":{"runAsNonRoot":true}}],"initContainers":[{"name":"init","image":"b","resources":{"limits":{"cpu":"100m"}},"securityContext":{"runAsNonRoot":true}}]}'
    want='{"containers":[{"image":"i","name":"app","resources":{},"securityContext":{}}],"initContainers":[{"name":"init","resources":{},"securityContext":{}}],"securityContext":{}}'
    for row in apps/v1\|Deployment\|spec.template.spec apps/v1\|StatefulSet\|spec.template.spec \
            apps/v1\|DaemonSet\|spec.template.spec batch/v1\|CronJob\|spec.jobTemplate.spec.template.spec; do
        IFS='|' read -r api kind path <<<"$row"
        pod_k "$api" "$kind" "$path" "$set" "$live"
        [ "$(pod_at "$path")" = "$want" ] || { echo "$row: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ] || { echo "$row: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "project: an owned {} at a container's resources or securityContext, or the pod's securityContext, absent live is left out" {
    # The server defaults resources and the pod's securityContext back to
    # {}, and a container's securityContext removed takes the leaf with it:
    # only an odd read gets here, and {} would add what the object lacks.
    local set row api kind path p
    set='{"f:securityContext":{},"f:containers":{"k:{\"name\":\"app\"}":{".":{},"f:name":{},"f:resources":{},"f:securityContext":{}}},"f:initContainers":{"k:{\"name\":\"init\"}":{".":{},"f:name":{},"f:resources":{},"f:securityContext":{}}}}'
    for row in apps/v1\|Deployment\|spec.template.spec apps/v1\|StatefulSet\|spec.template.spec \
            apps/v1\|DaemonSet\|spec.template.spec batch/v1\|CronJob\|spec.jobTemplate.spec.template.spec; do
        IFS='|' read -r api kind path <<<"$row"
        pod_k "$api" "$kind" "$path" "$set" '{"containers":[{"name":"app"}],"initContainers":[{"name":"init"}]}'
        [ "$(pod_at "$path")" = '{"containers":[{"name":"app"}],"initContainers":[{"name":"init"}]}' ] || { echo "$row: $MANAGEDFIELDS_PROJECTED"; return 1; }
        p=$(P=$path yq -n -o=json -I0 'strenv(P) | split(".") | map("f:" + .)')
        p=${p:1:${#p}-2}
        [ "$MANAGEDFIELDS_OMITTED" = "[[$p,\"f:securityContext\"],[$p,\"f:containers\",\"k:{\\\"name\\\":\\\"app\\\"}\",\"f:resources\"],[$p,\"f:containers\",\"k:{\\\"name\\\":\\\"app\\\"}\",\"f:securityContext\"],[$p,\"f:initContainers\",\"k:{\\\"name\\\":\\\"init\\\"}\",\"f:resources\"],[$p,\"f:initContainers\",\"k:{\\\"name\\\":\\\"init\\\"}\",\"f:securityContext\"]]" ] \
            || { echo "$row: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "project: the container {} rule holds only at a built-in kind's pod template" {
    # Each of these copies the live value: an ephemeral container (never in
    # a template), another list, the pod's own resources, a containers
    # map reached by field rather than by element, the name at the
    # workload's spec or at the other kind's template path, a field inside
    # one, another container field, a Rollout (whose template is a CRD
    # field), a Job, and a kind of a built-in name in another group.
    local c='{"f:containers":{"k:{\"name\":\"a\"}":{"f:name":{},"f:resources":{},"f:securityContext":{}}}}'
    local cl='{"containers":[{"name":"a","resources":{"limits":{"cpu":"1"}},"securityContext":{"runAsNonRoot":true}}]}'
    local sc='{"f:securityContext":{}}' scl='{"securityContext":{"fsGroup":1}}'
    local row api kind path set live
    for row in \
            'apps/v1|Deployment|spec.template.spec|{"f:ephemeralContainers":{"k:{\"name\":\"e\"}":{"f:name":{},"f:resources":{},"f:securityContext":{}}}}|{"ephemeralContainers":[{"name":"e","resources":{"limits":{"cpu":"1"}},"securityContext":{"runAsNonRoot":true}}]}' \
            'apps/v1|Deployment|spec.template.spec|{"f:sidecars":{"k:{\"name\":\"a\"}":{"f:name":{},"f:resources":{},"f:securityContext":{}}}}|{"sidecars":[{"name":"a","resources":{"limits":{"cpu":"1"}},"securityContext":{"runAsNonRoot":true}}]}' \
            'apps/v1|Deployment|spec.template.spec|{"f:resources":{}}|{"resources":{"limits":{"cpu":"1"}}}' \
            'apps/v1|Deployment|spec.template.spec|{"f:containers":{"f:a":{"f:resources":{}}}}|{"containers":{"a":{"resources":{"limits":{"cpu":"1"}}}}}' \
            "apps/v1|Deployment|spec|$sc|$scl" \
            "apps/v1|StatefulSet|spec.template|$sc|$scl" \
            "apps/v1|Deployment|spec|$c|$cl" \
            "apps/v1|DaemonSet|spec.template|$c|$cl" \
            'apps/v1|Deployment|spec.template.spec|{"f:containers":{"k:{\"name\":\"a\"}":{"f:name":{},"f:resources":{"f:limits":{}}}}}|{"containers":[{"name":"a","resources":{"limits":{"cpu":"1"}}}]}' \
            'apps/v1|Deployment|spec.template.spec|{"f:containers":{"k:{\"name\":\"a\"}":{"f:name":{},"f:lifecycle":{}}}}|{"containers":[{"name":"a","lifecycle":{"preStop":{"sleep":{"seconds":1}}}}]}' \
            'apps/v1|Deployment|spec.template.spec|{"f:securityContext":{"f:seLinuxOptions":{}}}|{"securityContext":{"seLinuxOptions":{"level":"s0"}}}' \
            "apps/v1|Deployment|spec.jobTemplate.spec.template.spec|$sc|$scl" \
            "batch/v1|CronJob|spec.template.spec|$c|$cl" \
            "batch/v1|CronJob|spec.jobTemplate.spec|$sc|$scl" \
            "apps/v1|CronJob|spec.jobTemplate.spec.template.spec|$sc|$scl" \
            "batch/v1|Deployment|spec.template.spec|$c|$cl" \
            "batch/v1|Job|spec.template.spec|$sc|$scl" \
            "argoproj.io/v1alpha1|Rollout|spec.template.spec|$sc|$scl" \
            "argoproj.io/v1alpha1|Rollout|spec.template.spec|$c|$cl" \
            'argoproj.io/v1alpha1|Rollout|spec.template.spec|{"f:initContainers":{"k:{\"name\":\"a\"}":{"f:name":{},"f:resources":{}}}}|{"initContainers":[{"name":"a","resources":{"limits":{"cpu":"1"}}}]}' \
            "example.com/v1|Deployment|spec.template.spec|$c|$cl" \
            "example.com/v1|StatefulSet|spec.template.spec|$sc|$scl" \
            "example.com/v1|CronJob|spec.jobTemplate.spec.template.spec|$c|$cl"; do
        IFS='|' read -r api kind path set live <<<"$row"
        pod_k "$api" "$kind" "$path" "$set" "$live"
        [ "$(pod_at "$path")" = "$(yq -p=json -o=json -I0 'sort_keys(..)' <<<"$live")" ] || { echo "$row: $MANAGEDFIELDS_PROJECTED"; return 1; }
        [ "$MANAGEDFIELDS_OMITTED" = '[]' ] || { echo "$row: $MANAGEDFIELDS_OMITTED"; return 1; }
    done
}

@test "csa_holders: names are shown for a log line, a line break as \\n and a control character as ?" {
    managedfields_csa_holders '{"metadata":{"managedFields":['"$(csa_entry 'a\nb' Update)"','"$(csa_entry 'c\u0001d' Update)"','"$(csa_entry 'a\nb' Update)"']}}'
    [ "$MANAGEDFIELDS_CSA_HOLDERS" = "'a\\nb', 'c?d'" ]
}

@test "name_shown: a written backslash and C1 controls cannot pass for an escape or a line break" {
    managedfields_name_shown 'a\nb'
    [ "$MANAGEDFIELDS_NAME_SHOWN" = 'a\\nb' ]
    managedfields_name_shown "$(printf 'a\nb')"
    [ "$MANAGEDFIELDS_NAME_SHOWN" = 'a\nb' ]
    managedfields_name_shown "$(printf 'a\xc2\x85b\xc2\x9fc')"
    [ "$MANAGEDFIELDS_NAME_SHOWN" = 'a?b?c' ]
    managedfields_name_shown "$(printf 'caf\xc3\xa9')"
    [ "$MANAGEDFIELDS_NAME_SHOWN" = "$(printf 'caf\xc3\xa9')" ]
}

@test "reshaped: only the pod lists a schema change can re-key count" {
    if managedfields_reshaped '{"f:spec":{"f:strategy":{}}}' '{"f:spec":{"f:strategy":{"f:type":{}}}}'; then false; fi
    managedfields_reshaped '{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}' '{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"a\"}":{}}}}}}'
    [ "$MANAGEDFIELDS_RESHAPED" = "spec.template.spec.containers" ]
    managedfields_reshaped '{"f:spec":{"f:strategy":{},"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{}}}}}}}' '{"f:spec":{"f:strategy":{"f:type":{}},"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:volumes":{"k:{\"name\":\"v\"}":{}}}}}}}}'
    [ "$MANAGEDFIELDS_RESHAPED" = "spec.jobTemplate.spec.template.spec.volumes" ]
}

@test "reshaped: a CronJob's jobTemplate containers list counts" {
    managedfields_reshaped '{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}}}' '{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"job\"}":{}}}}}}}}'
    [ "$MANAGEDFIELDS_RESHAPED" = "spec.jobTemplate.spec.template.spec.containers" ]
}

@test "reshaped: sets too big for one environment string are still read" {
    # 128 KiB is Linux's cap on one; past it yq is never run, and the
    # refusal fell back to the plain guard wording.
    local big before after
    big=$(head -c 140000 /dev/zero | tr '\0' x)
    before='{"f:metadata":{"f:annotations":{"f:'"$big"'":{}}},"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}'
    after='{"f:metadata":{"f:annotations":{"f:'"$big"'":{}}},"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"a\"}":{}}}}}}'
    managedfields_reshaped "$before" "$after"
    [ "$MANAGEDFIELDS_RESHAPED" = "spec.template.spec.containers" ]
}

@test "image_appliers: another Apply entry on the image is named" {
    managedfields_image_appliers '[{"manager":"argocd","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main owner
    [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'argocd'" ]
}

@test "image_appliers: the owner itself is not one" {
    local rc=0
    managedfields_image_appliers '[{"manager":"argocd","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main argocd || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$MANAGEDFIELDS_IMAGE_APPLIERS" ]
}

@test "image_appliers: keelson's own Apply entry is not one" {
    local rc=0
    managedfields_image_appliers '[{"manager":"keelson","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main owner || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$MANAGEDFIELDS_IMAGE_APPLIERS" ]
}

@test "image_appliers: an Update entry on the image is not one" {
    local rc=0
    managedfields_image_appliers '[{"manager":"helm","operation":"Update","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main owner || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$MANAGEDFIELDS_IMAGE_APPLIERS" ]
}

@test "image_appliers: a manager with two entries is named once" {
    managedfields_image_appliers '[{"manager":"flux","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},{"manager":"argocd","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},{"manager":"flux","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main owner
    [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'flux', 'argocd'" ]
}

@test "image_appliers: a CronJob's image under jobTemplate counts" {
    managedfields_image_appliers '[{"manager":"argocd","operation":"Apply","fieldsV1":{"f:spec":{"f:jobTemplate":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"job\"}":{"f:image":{}}}}}}}}}}]' containers job owner
    [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'argocd'" ]
}

@test "image_appliers: an ancestor held whole holds the image" {
    local fs
    for fs in '{"f:spec":{"f:template":{"f:spec":{"f:containers":{}}}}}' '{"f:spec":{}}'; do
        MANAGEDFIELDS_IMAGE_APPLIERS=""
        managedfields_image_appliers '[{"manager":"argocd","operation":"Apply","fieldsV1":'"$fs"'}]' containers main owner \
            || { echo "$fs: rc=$?"; return 1; }
        [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'argocd'" ] || { echo "$fs: $MANAGEDFIELDS_IMAGE_APPLIERS"; return 1; }
    done
}

@test "image_appliers: an owner or manager name holding * or ? is matched exactly" {
    managedfields_image_appliers '[{"manager":"ab","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},{"manager":"a?","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main 'a*'
    [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'ab', 'a?'" ]
    managedfields_image_appliers '[{"manager":"m*","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}},{"manager":"m?","operation":"Apply","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main m
    [ "$MANAGEDFIELDS_IMAGE_APPLIERS" = "'m*', 'm?'" ]
}

@test "image_appliers: an Apply entry on a subresource is not one" {
    local rc=0
    managedfields_image_appliers '[{"manager":"m","operation":"Apply","subresource":"status","fieldsV1":{"f:spec":{"f:template":{"f:spec":{"f:containers":{"k:{\"name\":\"main\"}":{"f:image":{}}}}}}}}]' containers main owner || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$MANAGEDFIELDS_IMAGE_APPLIERS" ]
}

@test "image_appliers: managedFields that cannot be read return 2, not none" {
    local mf rc
    for mf in '{}' 'not json ['; do
        rc=0
        managedfields_image_appliers "$mf" containers main owner || rc=$?
        [ "$rc" -eq 2 ] || { echo "$mf: rc=$rc"; return 1; }
    done
}

@test "image_appliers: a container name the key cannot carry as written is refused, not read as none" {
    local n rc
    for n in 'a<b' 'a>b' 'a&b' 'a"b' 'a\b' 'a*' 'a?' $'a\tb' $'a\x01b' $'a\xe2\x80\xa8b' $'a\xe2\x80\xa9b'; do
        rc=0
        managedfields_image_appliers '[{"manager":"m","operation":"Apply","fieldsV1":{}}]' containers "$n" owner || rc=$?
        [ "$rc" -eq 2 ] || { echo "$n: rc=$rc"; return 1; }
    done
}
