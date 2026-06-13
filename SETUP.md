# Datalake — MySQL → Airbyte → MinIO on AWS

A small Terraform setup that stands up a working data-ingestion sandbox on AWS:

- **MySQL** EC2 with a sample `sourcedb.customers` table (the data source)
- **Airbyte** (self-hosted via `abctl`, runs in a kind/Docker cluster) — the ingestion tool
- **MinIO** (S3-compatible object store) running in Docker on the same box — the destination

Everything runs in a dedicated VPC. The end goal: Airbyte reads rows from MySQL and lands them as files in a MinIO bucket.

```
┌────────────────────────── VPC 10.0.0.0/24 ──────────────────────────┐
│  public subnet 10.0.0.0/28                                           │
│                                                                      │
│   ┌───────────────┐         ┌──────────────────────────────────┐    │
│   │  mysql-source │  3306   │        airbyte-minio             │    │
│   │  (t3.medium)  │◄────────│  • MinIO   (Docker)  :9000/:9001 │    │
│   │  sourcedb     │         │  • Airbyte (abctl/kind) :8000    │    │
│   └───────────────┘         └──────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 0. Prerequisites

On your laptop:

- **Terraform** ≥ 1.5 — https://developer.hashicorp.com/terraform/install
- **AWS CLI** configured with credentials (`aws configure`) for an account you can launch EC2 in
- An **EC2 key pair** in region **eu-west-2 (London)** named `datapipeline_keypair`, and the matching `.pem` file saved locally
  - Create one: `aws ec2 create-key-pair --region eu-west-2 --key-name datapipeline_keypair --query 'KeyMaterial' --output text > datapipeline_keypair.pem && chmod 400 datapipeline_keypair.pem`
  - Or change the name in [ec2/variables.tf](ec2/variables.tf) to a key pair you already have.

> 💸 **Cost warning:** this launches a `t3.medium` and a `t3.xlarge` with 20 GB + 50 GB EBS. It is **not** free-tier. Destroy it when you're done (see step 7).

---

## 1. Get the code

```bash
git clone <this-repo-url>
cd datalake
git checkout refactor/vpc-ec2-modules   # the working branch
```

---

## 2. Deploy

```bash
terraform init
terraform plan      # review what will be created
terraform apply     # type "yes" to confirm
```

This creates: a VPC + public subnet + internet gateway + route table, a security group, and the two EC2 instances. When it finishes, Terraform prints outputs:

```
airbyte_minio_ip   = "x.x.x.x"
airbyte_ui_url     = "http://x.x.x.x:8000"
minio_console_url  = "http://x.x.x.x:9001"
mysql_public_ip    = "x.x.x.x"
```

The instances then run a boot script (`user_data`) that installs everything. **This takes ~15–30 min** (Airbyte pulls a lot of images). The EC2 "running" state in AWS appears long before the software is ready.

---

## 3. Verify the boot finished

SSH into the Airbyte box:

```bash
ssh -i datapipeline_keypair.pem ubuntu@<airbyte_minio_ip>
```

Run this one-liner to check everything:

```bash
echo "=== cloud-init ==="; cloud-init status --long; \
echo "=== docker ==="; sudo docker ps; \
echo "=== airbyte ==="; sudo abctl local status; \
echo "=== disk ==="; df -h /; \
echo "=== log tail ==="; sudo tail -n 40 /var/log/cloud-init-output.log
```

You want to see:
- `cloud-init status: done` (`running` = still installing, wait; `error` = a step failed, read the log tail)
- a `minio` container and `airbyte-abctl-control-plane` container in `docker ps`
- `abctl local status` reporting the cluster found

> ⚠️ **Always use `sudo` with `abctl`** on this box — the cluster is owned by root. Without sudo you'll get "No existing cluster found".

---

## 4. Open the UIs

| Service | URL | Login |
|---|---|---|
| MinIO console | `http://<airbyte_minio_ip>:9001` | `minioadmin` / `minioadmin123` |
| Airbyte | `http://<airbyte_minio_ip>:8000` | see **Known issues** below |

You should see the `mysql-ingest` bucket already created in MinIO.

---

## 5. Configure the pipeline in Airbyte

You need the **private IPs** of both boxes (Console → EC2 → Instances → Private IPv4). The boxes talk to each other over private IPs since they're in the same subnet.

**① Source → MySQL**

| Field | Value |
|---|---|
| Host | `<mysql private IP>` |
| Port | `3306` |
| Database | `sourcedb` |
| Username | `airbyte` |
| Password | `AirbytePass123!` |
| SSL mode | `preferred` (or disable) |

**② Destination → S3** (pointed at the local MinIO)

| Field | Value |
|---|---|
| S3 Bucket Name | `mysql-ingest` |
| S3 Bucket Region | `us-east-1` (placeholder — MinIO ignores it) |
| Access Key ID | `minioadmin` |
| Secret Access Key | `minioadmin123` |
| S3 Endpoint | `http://<airbyte-minio private IP>:9000` |
| Output format | JSONL or Parquet |

> Use the **private IP** for the S3 endpoint — `localhost` won't resolve from inside Airbyte's pods.

**③ Connection** — link Source → Destination, select the `customers` table (Full refresh), then **Sync now**.

**Verify the data landed** (on the box):

```bash
sudo docker run --rm --network host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin123 && mc ls -r local/mysql-ingest"
```

You should see output files — that's MySQL → Airbyte → MinIO working end-to-end. 🎉

---

## 6. Known issues / open items

- **Airbyte login is unresolved.** Plain `abctl local install` enables auth but leaves the admin email unset, so the UI login can reject you. This is the one piece not yet automated. Two ways to handle it (test on a fresh box before relying on it):
  1. `sudo abctl local install --disable-auth` — no login at all. ⚠️ Port 8000 is open to the internet, so only do this if you also restrict the `8000` rule in the security group to your own IP.
  2. **Keep auth, set real credentials** via abctl's `--values` / `--secret` file (preferred — more secure). *This is the planned approach.*
- **The connectors in step 5 are manual** (UI). They can be automated later via the Airbyte API / Terraform provider.
- **Security defaults are wide open** (SSH, MinIO, Airbyte ports allow `0.0.0.0/0`). Fine for a throwaway sandbox; tighten the security group in [ec2/main.tf](ec2/main.tf) before anything real.
- **Hardcoded passwords** (`AirbytePass123!`, `minioadmin123`) are in plain text in the config — sandbox only.

---

## 7. Tear it down (avoid charges)

```bash
terraform destroy   # type "yes"
```

This deletes the instances, VPC, and everything else. The key pair is not managed by Terraform, so it stays.

---

## File layout

```
.
├── main.tf            # root: provider + wires the two modules together
├── Vpc/               # VPC, public subnet, IGW, route table
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── ec2/               # security group + the two EC2 instances + boot scripts
    ├── main.tf
    └── variables.tf
```
