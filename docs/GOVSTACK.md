# GovStack G2P Bulk Disbursement Architecture

## Document Purpose

This document explains the GovStack Government-to-Person (G2P) bulk disbursement architecture as implemented in mifos-gazelle, based on the official GovStack specification and the actual codebase implementation.

**Key References:**
- GovStack Spec: `/home/tdaly/my-mac-dir/tmp/bulk-disburesement.pdf`
- Implementation: Payment Hub EE (PHEE) components in this repository

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Understanding Payment Modes](#understanding-payment-modes)
3. [GovStack Mode vs Payment Mode](#govstack-mode-vs-payment-mode)
4. [Component Details](#component-details)
5. [Workflow Comparison](#workflow-comparison)
6. [Current Implementation Issues](#current-implementation-issues)
7. [How to Fix and Run G2P Successfully](#how-to-fix-and-run-g2p-successfully)
8. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

### GovStack Specification Architecture

According to the official GovStack spec, the architecture for G2P bulk disbursement is:

```
┌────────────────────────────────────────────────────────┐
│  GOVERNMENT ENTITY (e.g., Social Welfare Ministry)     │
│  - Treasury Single Account (TSA)                       │
│  - Registration Building Block (beneficiary lists)     │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (2) Bulk Payment Batch
                   │ (RegisteringInstID, ProgramID, CSV)
                   ▼
┌────────────────────────────────────────────────────────┐
│  PAYMENTS BUILDING BLOCK (Payment Hub)                 │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Account Mapper (Identity Account Mapper)        │  │
│  │  - Pre-validates beneficiaries                   │  │
│  │  - Identifies payee FSPs                         │  │
│  │  - Payment modality lookup                       │  │
│  └──────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Bulk Processor                                   │  │
│  │  - De-bulks by receiving institution             │  │
│  │  - Creates sub-batches                           │  │
│  └──────────────────────────────────────────────────┘  │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (3) De-bulked Sub-batches
                   │ (grouped by Payee FSP)
                   ▼
┌────────────────────────────────────────────────────────┐
│  PAYER FSP (Payer Bank - e.g., Central Bank/State Bank)│
│  - Holds government settlement account                 │
│  - Participant in National Payment Switch              │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (4) Clearing Instructions
                   │ (per scheme rules)
                   ▼
┌────────────────────────────────────────────────────────┐
│  NATIONAL PAYMENT SWITCH / SCHEME                      │
│  - Routes to destination FSPs                          │
│  - Handles settlement                                  │
│  - Mojaloop vNext (in this implementation)             │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ (5) Individual Credits
          ┌────────┴────────┬────────────────┐
          ▼                 ▼                ▼
    ┌──────────┐      ┌──────────┐    ┌──────────┐
    │ Payee    │      │ Payee    │    │ Payee    │
    │ FSP 1    │      │ FSP 2    │    │ FSP 3    │
    │(bluebank)│      │(redbank) │    │(momo)    │
    └──────────┘      └──────────┘    └──────────┘
```

**Key Principle from GovStack Spec (Page 12-13):**
> "Payments Building Block does not interface directly with the Payment Switch. Payments Building Block interfaces with the Switch/Scheme through a Participant of the Switch/Scheme. The Payer forwards all instructions to the Scheme/Switch."

---

## Understanding Payment Modes

### Payment Mode != Architecture Mode

**CRITICAL**: The term "closedloop" in the codebase does NOT mean "single FSP" or "non-GovStack". It's a **workflow selector** based on the CSV `payment_mode` field.

### Payment Modes in CSV

The `payment_mode` column in the batch CSV determines which workflow is used:

| Payment Mode | Workflow BPMN | Purpose | Switch Involved? |
|--------------|---------------|---------|------------------|
| `closedloop` | `bulk_connector_closedloop-{dfspid}.bpmn` | Direct transfer via connector-bulk to channel connector | NO - bypasses switch |
| `mojaloop` | Uses switch routing workflows | Transfer via Mojaloop vNext switch | YES |
| `GSMA` | Uses GSMA connector | Mobile money via GSMA API | Depends on MNO |

**Configuration:** `ph-ee-bulk-processor/src/main/resources/application-paymentmode.yaml`

```yaml
- id: "CLOSEDLOOP"
  type: "BULK"
  endpoint: "bulk_connector_{MODE}-{dfspid}"
```

### Closedloop Workflow Behavior

When `payment_mode=closedloop` in CSV:

1. **Bulk-processor** calls connector-bulk's `BatchTransferWorker.processClosedloopTransfers()`
2. **Connector-bulk** makes HTTP POST directly to channel connector: `/channel/transfer`
3. **Channel connector** processes transfer WITHOUT going through switch
4. Transfer is executed within the SAME PHEE instance

**This is NOT GovStack compliant** because it bypasses the switch, but it's useful for:
- Testing
- Internal transfers within one institution
- Development environments

---

## GovStack Mode vs Payment Mode

### Two Independent Flags

#### 1. GovStack Mode (`--govstack` flag in submit-batch.py)

**What it does:**
- Sends `X-Registering-Institution-ID` header to bulk-processor
- Triggers `bulk_processor_account_lookup-{dfspid}.bpmn` workflow
- Calls identity-account-mapper for beneficiary validation
- Uses RegisteringInstitutionID for beneficiary lookup

**Code:** `submit-batch.py:116-119`
```python
if govstack:
    institution_id = registering_institution or tenant
    headers['X-Registering-Institution-ID'] = institution_id
```

**Triggered workflow:** `bulk_processor_account_lookup-greenbank.bpmn`
- Task: `batchAccountLookup` calls identity-account-mapper
- Callback: `batchAccountLookupCallback` receives beneficiary validation
- Then routes to payment execution based on CSV `payment_mode`

#### 2. Payment Mode (CSV `payment_mode` field)

**What it does:**
- Determines HOW the payment is executed
- Selects which connector to use
- Decides whether to use the switch

### Valid Combinations

| --govstack flag | payment_mode | Workflow | Use Case | Status |
|-----------------|--------------|----------|----------|--------|
| NO | closedloop | closedloop only | Simple testing, single FSP | ✅ WORKS |
| NO | mojaloop | mojaloop via switch | Multi-FSP, no identity mapper | 🔧 UNTESTED |
| **YES** | closedloop | account_lookup → closedloop | G2P with pre-validation, no switch | ❌ **BROKEN** (Issue #2) |
| **YES** | mojaloop | account_lookup → mojaloop | **TRUE GOVSTACK** - G2P via switch | 🔧 UNTESTED |

---

## Component Details

### 1. Identity Account Mapper

**Purpose (from GovStack spec page 7):**
> "The account mapper service identifies the FSP, and exact destination address where the merchant/agent/payee's account is used to route payouts to beneficiaries."

**Database:** `identity_account_mapper`

**Key Tables:**
```sql
-- Maps MSISDN to institution and payment modality
CREATE TABLE identity_details (
  id BIGINT PRIMARY KEY,
  payee_identity VARCHAR(255),  -- MSISDN (e.g., "0495822412")
  registering_institution_id VARCHAR(50),  -- "greenbank"
  payment_modality_id BIGINT
);

-- Stores account details
CREATE TABLE payment_modality_details (
  id BIGINT PRIMARY KEY,
  financial_address VARCHAR(255),  -- Account number (e.g., "000000001")
  institution_code VARCHAR(50),     -- FSP ID (e.g., "bluebank")
  modality VARCHAR(10)              -- "00" for MSISDN
);
```

**API:** `POST /api/v1/identity-account-mapper/batch-account-lookup`

**Request:**
```json
{
  "requestID": "batch-001",
  "registeringInstitutionID": "greenbank",
  "beneficiaries": [
    {
      "payeeIdentity": "0495822412",
      "paymentModality": "00"
    }
  ]
}
```

**Response (to callback URL):**
```json
{
  "requestID": "batch-001",
  "registeringInstitutionID": "greenbank",
  "beneficiaries": [
    {
      "payeeIdentity": "0495822412",
      "paymentModality": "00",
      "financialAddress": "000000001",
      "bankingInstitutionCode": "bluebank"
    }
  ]
}
```

**Critical Understanding:**
- The `financialAddress` (account number) is for **FSP identification and reconciliation**
- It should NOT replace the MSISDN for party lookup
- In true GovStack, the switch uses MSISDN for routing, and only the destination FSP uses the account number internally

### 2. Mojaloop vNext Switch

**Oracle Registration:**

The built-in oracle stores MSISDN → FSP mappings:

```
MSISDN: 0495822412 → fspId: "bluebank", currency: "USD"
MSISDN: 0424942603 → fspId: "bluebank", currency: "USD"
```

**How Routing Works:**
1. Payer FSP sends transfer request with MSISDN to switch
2. Switch queries oracle: "Which FSP owns this MSISDN?"
3. Oracle responds with FSP ID
4. Switch routes transfer to that FSP's callback URL
5. Destination FSP does party lookup with MSISDN

**Registration script:** `generate-mifos-vnext-data.py`

```python
def register_client_with_vnext(headers, tenant_id, mobile_number, currency="USD"):
    url = f"{VNEXT_BASE_URL}{mobile_number}"
    payload = {"fspId": tenant_id, "currency": currency}
    # Registers MSISDN in vNext oracle
```

### 3. Fineract Interop Identifier

Each Fineract tenant has an `interop_identifier` table:

```sql
-- bluebank database
SELECT * FROM interop_identifier;
-- Returns:
account_id | type   | value
1          | MSISDN | 0495822412
2          | MSISDN | 0424942603
```

This enables party lookup via Fineract API:
```
GET /fineract-provider/api/v1/interoperation/parties/MSISDN/0495822412
```

**Returns:**
```json
{
  "accountId": "5f695f3c-1e34-4e3d-941f-7547d19be343",
  "resourceId": 1,
  "resourceIdentifier": "1"
}
```

The `resourceIdentifier` is the savings account ID.

---

## Current Implementation Issues

### Issue #1: Batch ID Not Passed to Transfers (✅ FIXED)

**Problem:** connector-bulk's `BatchTransferWorker.invokeChannelTransfer()` didn't pass X-BatchID header.

**Fix Applied:** `ph-ee-connector-bulk/src/main/java/org/mifos/connector/phee/zeebe/workers/implementation/BatchTransferWorker.java:367-376`

```java
private boolean invokeChannelTransfer(Transaction transaction, String batchId, String tenant) {
    HttpHeaders headers = new HttpHeaders();
    headers.set("Platform-TenantId", tenant);
    headers.set("X-BatchID", batchId);              // ADDED
    headers.set("X-CorrelationID", transaction.getRequestId());  // ADDED
```

**Result:** Transfers are now properly linked to batches in the operations database.

### Issue #2: Payee Identifier Overwritten with Account Number (❌ ACTIVE BUG)

**Location:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/AccountLookupCallbackRoute.java:95`

**Buggy Code:**
```java
String identifier = matchingBeneficiary.get().getFinancialAddress();  // Gets "000000001"
transaction.setPayeeIdentifier(identifier);  // OVERWRITES MSISDN with account number!
transaction.setPayeeDfspId(matchingBeneficiary.get().getBankingInstitutionCode());
```

**What Happens:**
1. CSV has `payee_identifier = "0495822412"` (MSISDN)
2. Identity mapper returns `financialAddress = "000000001"` (account number)
3. Line 95 overwrites: `transaction.payeeIdentifier = "000000001"`
4. Channel connector tries party lookup: `GET /parties/MSISDN/000000001`
5. Fineract has no interop_identifier with value='000000001'
6. **Result:** PARTY_NOT_FOUND error (code 3204)

**Why This is Wrong:**

According to GovStack spec:
- The `financialAddress` is for **FSP identification** and **internal use by destination FSP**
- The MSISDN should be preserved for party lookup
- Account number is metadata for reconciliation, not for party lookup

**Impact:**
- Breaks `--govstack` mode with `payment_mode=closedloop`
- Prevents G2P payments from working
- Transfers remain stuck in IN_PROGRESS status

### Issue #3: Architecture Mismatch

**Current Setup:**
- Single PHEE instance handling multiple FSPs as tenants
- Identity-account-mapper enabled (GovStack component)
- Using closedloop payment mode (bypasses switch)

**The Conflict:**
When you run `--govstack --registering-institution greenbank` with `payment_mode=closedloop`:
1. Identity mapper returns account number for cross-FSP routing
2. But closedloop mode doesn't do cross-FSP routing (same PHEE instance)
3. Same PHEE tries to do party lookup with account number
4. Fails

---

## How to Fix and Run G2P Successfully

### Quick Fix: Option A - Disable Identity Mapper (Simplest)

**For testing/development when you don't need cross-FSP validation:**

1. **Don't use `--govstack` flag**
2. **Use simple closedloop CSV format**

**CSV Format:**
```csv
id,request_id,payment_mode,payer_identifier_type,payer_identifier,payee_identifier_type,payee_identifier,amount,currency,note,account_number
0,xxx,closedloop,MSISDN,0413356886,MSISDN,0495822412,10,USD,Test,1
```

**Command:**
```bash
cd /home/tdaly/mifos-gazelle/src/utils/data-loading
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-closedloop-4.csv
# NO --govstack flag
```

**What Happens:**
- Skips identity-account-mapper
- Uses MSISDN directly for party lookup
- Works within single PHEE instance

**Verify:**
```bash
# Check batch status
kubectl logs -n paymenthub -l app=ph-ee-operations-app --tail=50 | grep -i batch

# Check transfers
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT id, batch_id, payee_identifier, status FROM transfers ORDER BY id DESC LIMIT 5"
```

✅ **This should work immediately.**

---

### Proper Fix: Option B - Fix the Code (GovStack Compliant)

**For production G2P payments with proper validation:**

#### Step 1: Fix AccountLookupCallbackRoute.java

**File:** `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/AccountLookupCallbackRoute.java`

**Change line 95 from:**
```java
String identifier = matchingBeneficiary.get().getFinancialAddress();
transaction.setPayeeIdentifier(identifier);  // BUG: overwrites MSISDN
```

**To:**
```java
String accountNumber = matchingBeneficiary.get().getFinancialAddress();
// Keep MSISDN for party lookup, store account number separately
transaction.setPayeeAccountNumber(accountNumber);  // New field for reconciliation
// Don't overwrite payeeIdentifier - keep original MSISDN!
```

**You'll also need to:**

1. Add `payeeAccountNumber` field to `Transaction.java` schema
2. Store it in sub_batch_transaction table
3. Use it for reconciliation, NOT for party lookup

#### Step 2: Rebuild and Redeploy

```bash
cd /home/tdaly/ph-ee-bulk-processor
./gradlew bootJar

# Restart bulk-processor pod
kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor
```

#### Step 3: Test with GovStack Mode

```bash
cd /home/tdaly/mifos-gazelle/src/utils/data-loading

# Make sure beneficiaries are registered
python3 generate-mifos-vnext-data.py --regenerate

# Submit with govstack flag
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-govstack-4.csv \
  --govstack --registering-institution greenbank
```

**Expected Flow:**
1. Identity mapper validates beneficiaries ✓
2. Returns account numbers for reconciliation ✓
3. MSISDN preserved for party lookup ✓
4. Party lookup succeeds ✓
5. Transfers complete ✓

---

### Advanced: Option C - True GovStack with Switch (Future)

**For real multi-FSP deployment:**

#### Step 1: Use mojaloop Payment Mode

**CSV Format:**
```csv
id,request_id,payment_mode,payee_identifier_type,payee_identifier,amount,currency,note
0,xxx,mojaloop,MSISDN,0495822412,10,USD,G2P Payment
```

**Note:** `payment_mode=mojaloop` instead of `closedloop`

#### Step 2: Submit with GovStack Flag

```bash
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-mojaloop-4.csv \
  --govstack --registering-institution greenbank
```

**Expected Flow:**
1. Identity mapper validates beneficiaries
2. Bulk processor de-bulks by FSP (based on `bankingInstitutionCode`)
3. Sub-batches sent to Payer FSP (greenbank participant)
4. Payer FSP → Mojaloop vNext switch
5. Switch queries oracle: MSISDN → FSP mapping
6. Switch routes to destination FSP (bluebank)
7. Bluebank FSP does party lookup with MSISDN
8. Bluebank credits account

**This is spec-compliant GovStack G2P.**

🔧 **Status:** Needs testing - workflow exists but may need connector configuration.

---

## Step-by-Step: Getting G2P Working NOW

### Prerequisites Check

```bash
# 1. Verify all pods running
kubectl get pods -n paymenthub
kubectl get pods -n vnext
kubectl get pods -n mifosx
kubectl get pods -n infra

# 2. Check beneficiaries registered
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT id.payee_identity, pmd.financial_address, pmd.institution_code
   FROM identity_details id
   JOIN payment_modality_details pmd ON id.payment_modality_id = pmd.id
   WHERE id.registering_institution_id = 'greenbank'
   LIMIT 5"

# If empty, register beneficiaries:
cd /home/tdaly/mifos-gazelle/src/utils/data-loading
python3 generate-mifos-vnext-data.py --regenerate
```

### Working Solution (Option A - No GovStack Flag)

```bash
cd /home/tdaly/mifos-gazelle/src/utils/data-loading

# 1. Use the closedloop CSV (no --govstack flag needed)
cat bulk-gazelle-closedloop-4.csv
# Verify it has: payment_mode=closedloop, payer and payee MSISDNs

# 2. Submit batch WITHOUT --govstack flag
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-closedloop-4.csv

# 3. Monitor processing
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=100 -f

# 4. Check results
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT
    b.batch_id,
    b.total,
    b.successful,
    b.failed,
    b.ongoing,
    COUNT(t.id) as transfer_count,
    GROUP_CONCAT(DISTINCT t.status) as statuses
   FROM batch b
   LEFT JOIN transfers t ON b.batch_id = t.batch_id
   GROUP BY b.batch_id
   ORDER BY b.id DESC
   LIMIT 3"
```

**Expected Output:**
```
batch_id | total | successful | failed | ongoing | transfer_count | statuses
xxxxx    |   4   |     4      |   0    |    0    |       4        | COMPLETED
```

### If You See Issues:

#### Issue: PARTY_NOT_FOUND

```bash
# Check what identifier was used
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT payee_identifier FROM transfers ORDER BY id DESC LIMIT 1"

# If shows account number (000000001) instead of MSISDN (0495822412):
# You accidentally used --govstack flag OR CSV is in wrong format
```

**Fix:** Use closedloop CSV without --govstack flag.

#### Issue: Zero Total

```bash
# Check if identity mapper was called (should NOT be if no --govstack flag)
kubectl logs -n paymenthub -l app=ph-ee-identity-account-mapper --tail=50

# If you see logs, you used --govstack flag accidentally
```

**Fix:** Resubmit without --govstack flag.

#### Issue: Batch ID NULL

```bash
# Check if connector-bulk has the fix
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, client_correlation_id FROM transfers ORDER BY id DESC LIMIT 1"

# If batch_id is NULL:
# The BatchTransferWorker fix wasn't applied or connector-bulk wasn't restarted
```

**Fix:**
```bash
cd /home/tdaly/ph-ee-connector-bulk
./gradlew bootJar
kubectl delete pod -n paymenthub -l app=ph-ee-connector-bulk
```

---

## Troubleshooting Guide

### Diagnostic Commands

```bash
# 1. Check batch status
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, total, successful, failed, ongoing FROM batch ORDER BY id DESC LIMIT 3"

# 2. Check transfer details
kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
  "SELECT id, batch_id, payee_identifier, payee_dfsp_id, status FROM transfers ORDER BY id DESC LIMIT 5"

# 3. Check bulk-processor logs
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor --tail=100

# 4. Check connector-bulk logs
kubectl logs -n paymenthub -l app=ph-ee-connector-bulk --tail=100

# 5. Check channel connector logs
kubectl logs -n paymenthub -l app=ph-ee-connector-channel --tail=100

# 6. Check identity mapper (if using --govstack)
kubectl logs -n paymenthub -l app=ph-ee-identity-account-mapper --tail=50

# 7. Verify beneficiary registration
kubectl exec -n infra mysql-0 -- mysql -umifos -ppassword identity_account_mapper -e \
  "SELECT COUNT(*) as beneficiary_count FROM identity_details WHERE registering_institution_id='greenbank'"
```

### Common Error Patterns

| Symptom | Cause | Solution |
|---------|-------|----------|
| Batch total = 0 | Identity mapper returned empty list | Check registering_institution_id matches, or don't use --govstack |
| PARTY_NOT_FOUND | Payee identifier overwritten with account# | Don't use --govstack flag (Option A) or fix code (Option B) |
| Transfers IN_PROGRESS forever | Party lookup failing | Check channel connector logs for error details |
| batch_id NULL in transfers | BatchTransferWorker missing headers | Apply fix and rebuild connector-bulk |
| 500 from identity mapper | Beneficiaries not registered | Run `generate-mifos-vnext-data.py --regenerate` |

---

## Summary

### Key Takeaways

1. **Closedloop ≠ Non-GovStack**
   - "closedloop" is a payment mode (workflow), not an architecture
   - You can have GovStack validation with closedloop routing (broken currently)
   - You can have mojaloop routing without GovStack validation

2. **Two Independent Flags:**
   - `--govstack` = enables identity mapper validation
   - `payment_mode` in CSV = selects routing method

3. **Current Bug:**
   - Identity mapper overwrites MSISDN with account number
   - Breaks party lookup in closedloop mode
   - Needs code fix in AccountLookupCallbackRoute.java

4. **Working Solution:**
   - Don't use `--govstack` flag
   - Use closedloop CSV with MSISDNs
   - Transfers work within single PHEE instance

5. **Future GovStack:**
   - Fix the code to preserve MSISDN
   - Use `payment_mode=mojaloop` for switch routing
   - Deploy multiple PHEE instances per FSP

### Quick Reference

**To run G2P payments NOW:**
```bash
cd /home/tdaly/mifos-gazelle/src/utils/data-loading
./submit-batch.py -c ~/tomconfig.ini -f bulk-gazelle-closedloop-4.csv
# NO --govstack flag!
```

**To fix for proper GovStack:**
1. Edit `AccountLookupCallbackRoute.java:95`
2. Don't overwrite `payeeIdentifier`
3. Store account number in separate field
4. Rebuild and test

---

## File References

### Bulk Processor
- Workflow: `orchestration/feel/bulk_processor_account_lookup-DFSPID.bpmn`
- Account Lookup: `ph-ee-bulk-processor/src/main/java/org/mifos/processor/bulk/camel/routes/AccountLookupCallbackRoute.java:95` (**BUG HERE**)
- Payment Mode Config: `ph-ee-bulk-processor/src/main/resources/application-paymentmode.yaml`

### Connector Bulk
- Batch Transfer: `ph-ee-connector-bulk/src/main/java/org/mifos/connector/phee/zeebe/workers/implementation/BatchTransferWorker.java:367-376` (✅ FIXED)
- Closedloop Workflow: `orchestration/feel/bulk_connector_closedloop-DFSPID.bpmn`

### Test Data
- Closedloop CSV: `src/utils/data-loading/bulk-gazelle-closedloop-4.csv`
- GovStack CSV: `src/utils/data-loading/bulk-gazelle-govstack-4.csv`
- Submit Script: `src/utils/data-loading/submit-batch.py`
- Data Generator: `src/utils/data-loading/generate-mifos-vnext-data.py`

### Configuration
- PHEE Values: `config/ph_values.yaml`
- Mojaloop Config: `config/ph_values.yaml:245-271`

---

**Last Updated:** Based on investigation and GovStack spec analysis December 2024
