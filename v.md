# CPT-XXXX: Assuming an IAM role in the Vault provider

**Status:** Investigation findings
**Parent:** CPT-XXXX

## Summary

The Vault provider can assume an IAM role at the provider level, using `aws_role_arn` in the `auth_login_aws` block. This approach is feasible.

For it to work, the role the provider is running as (the **role in effect**) must be allowed to assume the target role.

## Implementation

```hcl
provider "vault" {
  address = var.vault_addr

  auth_login_aws {
    role                  = var.vault_aws_auth_role   # Vault AWS auth role name
    mount                 = "aws"
    aws_role_arn          = var.vault_login_role_arn  # target IAM role to assume
    aws_role_session_name = "tfc-${var.workspace_name}"
    aws_region            = var.aws_region
  }
}
```

The provider assumes the target role, then logs in to Vault's AWS auth method as that role.

## Required configuration

### Role in effect: permissions policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/<TARGET_VAULT_LOGIN_ROLE>"
    }
  ]
}
```

### Target role: trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_IN_EFFECT>"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Vault

| Setting | Value |
| --- | --- |
| AWS auth role `auth_type` | `iam` |
| AWS auth role `bound_iam_principal_arn` | The target role's ARN |
| AWS auth role `token_policies` | The workspace's Vault policies |

## Role in effect: observed behaviour

The Vault provider finds its AWS credentials differently from the AWS provider. So in the same run, it may use a different role from the AWS provider.

In workspaces with `TFC_AWS_PROVIDER_AUTH = true`, we have seen both outcomes:

| Workspace | Role in effect for the Vault provider |
| --- | --- |
| Workspace 1 | ECS task role (agent) |
| Workspace 2 | TFC workspace role (`TFC_AWS_RUN_ROLE_ARN`) |

**Likely cause:** Workspace 2 used a later version of the Vault provider. Newer versions may pick up HCP Terraform's dynamic AWS credentials, while older versions fall back to the ECS task role. This needs further investigation to confirm.

Until confirmed, the role in effect should be checked per workspace before granting `sts:AssumeRole` on the target role.

## Recommendation

- Set `aws_role_arn` explicitly in every Vault provider block, with a dedicated Vault login role per workspace.
- Bind the Vault AWS auth role to that login role.
- Grant `sts:AssumeRole` on the login role to the role in effect for that workspace.

## Next steps

1. Compare Vault provider versions between the two workspaces (`.terraform.lock.hcl`).
2. Confirm which role each version uses. Vault's login error and audit log show the exact IAM principal presented.
3. Agree on a minimum Vault provider version so the role in effect is consistent.

## References

- [Vault provider: `auth_login_aws` arguments](https://github.com/hashicorp/terraform-provider-vault/blob/main/website/docs/index.html.markdown)
- [HCP Terraform: dynamic credentials with the AWS provider](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/aws-configuration)
