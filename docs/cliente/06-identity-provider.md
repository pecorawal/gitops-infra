# 6. Identity Provider (OAuth do cluster)

Configura o objeto **`OAuth/cluster`** — a lista de identity providers que o
cluster aceita no login. O exemplo entregue no `values.yaml` é um **OpenID
Connect contra o Microsoft Entra ID**, mas o chart repassa a lista crua, então
qualquer `type` suportado pelo OpenShift (LDAP, HTPasswd, GitHub…) funciona.

| | |
|---|---|
| Chart | `charts/identity-provider` |
| Application | `idp-<cluster>` (sync-wave **70**, no spoke) |
| Objeto | `config.openshift.io/v1 OAuth` — singleton `cluster` |
| Interruptor | `identityProvider.enabled` |

A wave 70 é a última de propósito: é a camada que mexe no **login**. Se algo
estiver errado aqui, todo o resto já subiu e o `kubeadmin` continua valendo para
entrar e corrigir.

## 6.1 Três avisos que valem antes de ligar

**A lista é atômica.** `spec.identityProviders` substitui integralmente o que
está no cluster. Um provider adicionado pela console será **removido** no próximo
sync, porque o `selfHeal` está ligado. Todo provider tem que estar declarado no
`values.yaml`.

**O objeto não é nosso.** O `OAuth/cluster` nasce com a instalação, com spec
vazio. O chart usa `ServerSideApply=true` para gerenciar só o campo
`identityProviders`, sem assumir a posse do objeto — mesma abordagem do
`IngressController/default` e do `CertManager/cluster`.

**O login cai por ~1 minuto.** Ao sincronizar, o `authentication-operator`
reescreve a configuração e reinicia os pods do `oauth-server`:

```bash
oc get co authentication -w
oc get pods -n openshift-authentication
```

## 6.2 Registro no Entra ID (uma vez, pelo time de identidade)

1. **Redirect URI** (tipo *Web*), com o `name` do provider no final:

   ```
   https://oauth-openshift.apps.<cluster>.cgibs.gov.br/oauth2callback/RTC_EntraID
   ```

   > O `name` do provider entra na URL. Mudá-lo depois quebra o callback e exige
   > atualizar o registro no Entra ID — escolha e não mexa mais.

   O host é o do IngressController **`default`** (a rota `oauth-openshift` é de
   plataforma e não tem a label `ingress-type`). Confirme o valor real com:

   ```bash
   oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}{"\n"}'
   ```

2. **Token configuration → adicionar claim opcional `groups`.** Sem isso o claim
   `groups` chega vazio e nenhum `RoleBinding` por grupo funciona.

3. Anotar **Application (client) ID** e **Directory (tenant) ID**, e gerar um
   **client secret**.

## 6.3 Criar o Secret no cluster

O client secret **não vai para o Git**. Ele vive num Secret no namespace
`openshift-config` (exigência do `authentication-operator`), com a chave
obrigatoriamente chamada `clientSecret`:

```bash
oc login <api-do-spoke>
./docs/cliente/scripts/criar-secrets-day2.sh clusters/<cluster>/values.yaml
```

O script pede o secret na etapa 4. Manualmente seria:

```bash
oc create secret generic openid-client-secret -n openshift-config \
  --from-literal=clientSecret='<secret-do-entra-id>'
```

> Este é o client secret do **registro de aplicação** do Entra ID. Não é o mesmo
> Service Principal usado para DNS/NSG nas etapas anteriores.

## 6.4 Preencher e ligar

```yaml
identityProvider:
  enabled: true
  providers:
    - name: RTC_EntraID
      type: OpenID
      mappingMethod: claim
      openID:
        clientID: "<application-client-id>"
        clientSecret:
          name: openid-client-secret
        issuer: "https://login.microsoftonline.com/<tenant-id>/v2.0"
        extraScopes: [profile, openid]
        claims:
          preferredUsername: [preferred_username]
          name: [name]
          email: [email]
          groups: [groups]
```

O chart **falha o render** se sobrar algum `<PREENCHER>` ou se a lista estiver
vazia com `enabled: true` — nesse caso o OAuth seria aplicado sem provider
nenhum e só o `kubeadmin` conseguiria entrar.

Commite. Verifique:

```bash
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}{"\n"}'
oc get co authentication
oc get pods -n openshift-authentication
```

E teste o login pela console — o botão `RTC_EntraID` deve aparecer ao lado de
`kube:admin`.

## 6.5 Dar permissão aos usuários

`mappingMethod: claim` cria o `User` no primeiro login, mas **sem nenhuma
permissão** — quem entra vê um cluster vazio. Isso é esperado.

Se o claim `groups` estiver chegando, o OpenShift sincroniza os grupos do token
e basta referenciá-los:

```bash
# confirme que o grupo chegou (depois do primeiro login de alguém do grupo)
oc get groups

oc adm policy add-cluster-role-to-group cluster-admin '<id-ou-nome-do-grupo>'
oc adm policy add-role-to-group edit '<grupo>' -n <namespace>
```

Se `oc get groups` vier vazio, o claim opcional `groups` não foi adicionado no
registro do Entra ID (passo 6.2.2). Confira o token com
`oc get user ~ -o yaml` e os logs:

```bash
oc logs -n openshift-authentication -l app=oauth-openshift --tail=100
```

> Os `RoleBinding`/`ClusterRoleBinding` **não** estão neste chart. Se quiser
> versioná-los, o caminho é um manifesto novo no `charts/identity-provider`
> ou um chart próprio — ver [05-estender.md](05-estender.md) §5.2 e §5.3.

## 6.6 Remover o kubeadmin

Só **depois** de validar o login pelo IdP **e** de confirmar que alguém tem
`cluster-admin` por grupo. Não há volta:

```bash
oc get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .subjects[]?.name'

oc delete secret kubeadmin -n kube-system
```

## 6.7 Erros comuns

| Sintoma | Causa |
|---|---|
| `error=invalid_request` / `redirect_uri mismatch` | Redirect URI no Entra ID não bate com o `name` do provider ou com o host real da rota `oauth-openshift` |
| Botão do IdP não aparece na console | Sync não chegou, ou `authentication` ainda reconciliando (`oc get co authentication`) |
| Login funciona mas o usuário não vê nada | Esperado — falta RoleBinding (§6.5) |
| `oc get groups` vazio | Claim opcional `groups` não configurado no Entra ID |
| Provider adicionado pela console some | Esperado — lista atômica + `selfHeal` (§6.1) |
| `authentication` fica `Degraded` com `secret ... not found` | O Secret não existe em `openshift-config` ou a chave não se chama `clientSecret` |
