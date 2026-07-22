### create k8s secret

make sure the following snipped exists in .sops.yaml

```yaml
- path_regex: cluster/.*\.ya?ml$
encrypted_regex: ^(data|stringData)$
key_groups:
- age:
    - *operator
```

create the secret with secret values in plain text eg.:

```yaml
# cluster/path/to/foobar.yaml
apiVersion: v1
kind: Secret
metadata:
    name: foobar
    namespace: foobar
type: Opaque
stringData:
    foobar: foobar
```

encrypt secret 
```
sops -e -i cluster/path/to/foobar.yaml
```