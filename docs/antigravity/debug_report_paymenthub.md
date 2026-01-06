# Debugging Report: Payment Hub Failures

## Analysis of Pod Failures
The following pods were reported as failing with `CrashLoopBackOff`:
- `ph-ee-connector-ams-mifos`
- `ph-ee-connector-channel`
- `ph-ee-connector-mojaloop-java`
- `ph-ee-zeebe-ops`
- `ph-ee-operations-app`

### Root Cause Analysis
1.  **Zeebe Connectivity (Critical)**:
    -   Configuration Analysis: `config/ph_values.yaml` showed `zeebe-gateway.enabled: false`.
    -   Impact: The failing components (`zeebe-ops`, `connectors`) likely rely on the standalone Zeebe Gateway service to communicate with the workflow engine. With the gateway disabled, these services fail to connect and crash on startup.
    -   Critique: Disabling the gateway saves memory (~450Mi) but breaks clients that aren't configured to use the headless broker service directly.

2.  **Memory Constraints**:
    -   Configuration Analysis: `ph-ee-operations-app` was configured with `-Xmx256m`.
    -   Impact: This is extremely tight for a Spring Boot application running a UI backend. It likely causes startup slowness or immediate OutOfMemory errors, contributing to the crashes.

## Applied Fixes
1.  **Enabled Zeebe Gateway**:
    -   Modified `config/ph_values.yaml` to set `zeebe-gateway.enabled: true`.
    -   This restores the standard connection point for all Payment Hub connectors.

2.  **Increased Memory Limits**:
    -   Bumped `ph-ee-operations-app` heap to `-Xmx512m` (and start at 128m) to provide breathing room.

## Recommendations
-   **Apply Changes**: Run the redeployment command:
    ```bash
    ./run.sh -u $USER -m deploy -a phee -r true
    ```
-   **Monitor**: Check if `zeebe-gateway` comes up first, followed by the connectors.
-   **Further Optimization**: If RAM is still a concern, we can look at tuning `zeebe-broker` memory down slightly (currently 1.2GB request / 1.9GB limit), but ensuring connectivity is priority #1.
