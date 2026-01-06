# Repository Analysis: Mifos Gazelle

## Executive Summary
Mifos Gazelle is a **Deployment as a Service (DaaS)** tool designed to orchestrate the deployment of the Mifos Digital Public Goods (DPGs) ecosystem on Kubernetes. It is currently at **v1.1.0** (July 2025).

The repository serves as a master orchestrator that uses Bash scripts to drive Helm charts, managing the complex dependencies between:
1.  **MifosX (Fineract)**: Core Banking Solution.
2.  **Payment Hub EE (PHEE)**: Middleware for payment orchestration (Zenbe-based).
3.  **Mojaloop vNext**: Financial transaction switch (Beta1).

## Architecture

### Tech Stack
-   **Orchestration Logic**: Bash Scripts (`src/deployer/*.sh`).
-   **Infrastructure Management**: Helm Charts (`src/deployer/helm`).
-   **Workflow Engine**: Camunda Zeebe (BPMN files in `orchestration/feel`).
-   **Database**: MySQL (MifosX, PHEE), MongoDB (vNext).
-   **Messaging**: Kafka (via Redpanda/Zeebe exporters).
-   **Search/Logs**: Elasticsearch & Kibana.

### Deployment Flow
The entry point is `run.sh`, which calls `src/commandline/commandline.sh` and then `src/deployer/deployer.sh`. The deployment process follows these stages:

1.  **Infrastructure Initialization**: Deploys shared services (MySQL, Elastic, etc.) to the `infra` namespace.
2.  **Service Deployment**:
    -   **vNext**: Clones `mifos-vnext` repo and deploys Helm/manifests.
    -   **Payment Hub**: Clones `ph-ee-env-template` and deploys Helm charts configured via `config/ph_values.yaml`.
    -   **MifosX**: Deploys Fineract and Web App manifests.
3.  **Data Seeding**:
    -   Restores DB dumps (`fineract-db-dump*.sql`, `mongodump.gz`).
    -   Runs `generate-mifos-vnext-data.py` to sync associations between MifosX and vNext.
4.  **BPMN Upload**: Uploads workflow definitions (`.bpmn` files) to the Zeebe broker.

## Directory Structure Deep Dive

| Directory | Purpose |
| :--- | :--- |
| `config/` | Central configuration. `ph_values.yaml` is critical for Payment Hub settings. Contains DB dumps. |
| `src/deployer/` | Core logic. `deployer.sh` contains functions for `deployPH`, `deployvNext`, `isPodRunning`, etc. |
| `src/deployer/helm/` | Local Helm charts (e.g., `infra` chart for shared services). |
| `orchestration/feel` | BPMN workflow definitions for the Payment Hub (e.g., `PayerFundTransfer`, `PayeeQuoteTransfer`). |
| `src/utils/` | Operational scripts: `make-payment.sh` (demo flow), `mysql-client-mifos.sh` (DB access), `install-k9s.sh`. |

## Key Concepts & terminology
-   **Greenbank / Bluebank**: Pre-configured tenants/banks for demonstration purposes.
-   **PHEE**: Payment Hub Enterprise Edition.
-   **Zeebe**: The workflow engine powering PHEE.
-   **DFSP**: Digital Financial Service Provider (e.g., a bank connecting to Mojaloop).

## Observations & Recommendations
-   **Bash Dependency**: The logic is heavily reliant on Bash and `kubectl` cli parsing. This makes it brittle to output changes in newer k8s versions.
-   **Memory Usage**: Requires significant RAM (24GB+) due to running three full stacks (MifosX + PHEE + vNext).
-   **Security**: The README explicitly states this is **not secure** and for dev/test only (hardcoded passwords, self-signed certs).
