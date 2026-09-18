# Calcar
## Product Requirements Document

**Version:** 1.1  
**Status:** Product Definition  
**Date:** September 2026

---

# 1. Product Summary

Calcar is a mobile application for remotely monitoring and controlling AI coding agents and development workflows running on a user's computers.

The product separates the user interface from the execution environment. The mobile application acts as the remote control. The user's Windows computer remains the execution environment where AI agents, terminals, scripts, builds, training jobs, Docker workloads, and project files run.

A lightweight Calcar Agent runs on each managed computer. The Agent provides device identity, trust management, workflow management, session persistence, provider integration, event streaming, command routing, permission handling, and network communication.

The mobile application provides a simple interface for managing these workflows. A user can select a computer, see its active workflows, inspect agent activity, send instructions, approve requests, stop workflows, and receive notifications.

Calcar is designed around a phone-first trust model. The user's first trusted phone becomes the Owner Device. A computer requests authorization from the Owner Device. The computer does not become the authority that decides which phones can control it.

---

# 2. Problem Statement

AI coding agents can perform long-running development tasks with limited user interaction. A developer can start an agent on a computer and leave while the agent continues working.

Existing development workflows often require the developer to return to the computer to inspect progress, answer an approval request, send another instruction, stop a process, or determine whether a task has completed.

This becomes harder when several agents and development jobs run at the same time. A Windows computer can contain many processes, terminals, shells, Python jobs, package managers, build systems, containers, and AI agent processes. Exposing this process-level complexity directly to a mobile user would create a poor interface.

Calcar introduces a workflow abstraction. The user interacts with meaningful development activities rather than individual operating-system processes.

The product also has a security requirement during initial setup. A computer that is already compromised must not be able to declare itself trusted and then authorize an attacker's phone.

---

# 3. Product Vision

Calcar should make a computer running AI development agents feel like a remote development environment that the user can control from a phone.

The user should be able to leave the computer and continue their day while still knowing what their development environment is doing.

The primary experience should answer three questions quickly:

**What is running?**

**What needs my attention?**

**What can I do about it?**

Calcar should hide operating-system complexity while preserving access to the underlying development environment when deeper control is required.

---

# 4. Product Goals

Calcar must provide reliable remote monitoring and control of AI development workflows running on user-owned computers.

The product must allow users to securely add computers, establish device identity, manage trusted devices, and revoke access.

AI agent sessions must continue running on the computer when the phone disconnects or the network connection temporarily fails.

Users must be able to reconnect later and recover the existing workflow state and agent session.

The product must support multiple AI coding providers through a common workflow interface.

Approval requests must be surfaced to the phone so users do not need to remain in front of the computer.

The product must provide enough workflow information for users to understand what an agent is doing without exposing the complete Windows process tree.

The architecture must keep the mobile application lightweight so older supported phones can be used as dedicated Calcar devices.

Security must be part of the architecture from the start.

---

# 5. Non-Goals

Calcar is not intended to replace a full desktop development environment.

The mobile application is not a complete IDE. It is a remote control and monitoring interface.

Calcar does not attempt to make a completely compromised computer trustworthy. If an attacker has full control of the operating system, Calcar cannot guarantee that information reported by the computer is truthful.

Calcar does not expose every Windows process as a separate user-facing object. Processes are implementation details inside workflows.

Calcar does not require public SSH exposure.

Calcar is not intended to provide unrestricted remote access without authentication and device authorization.

---

# 6. Target Users

The primary user is a developer who uses AI coding agents on a Windows computer.

This includes developers using tools such as OpenCode, Claude Code, Codex, and similar terminal-based agents. It also includes users running Python training jobs, scripts, builds, tests, Docker workloads, and other long-running development tasks.

The product also supports users who own several computers. One phone should be able to manage multiple trusted computers.

A further use case is a user with an older phone that is no longer their primary device. Because Calcar is designed as a thin client, such a phone can be connected to Wi-Fi and used as a dedicated development control panel.

---

# 7. Product Principles

Calcar follows a phone-first trust model.

The first trusted phone is the Owner Device. It establishes the initial authority for the Calcar installation.

A computer requests authorization. It does not grant authorization to itself.

Device identity is independent of network location. An IP address, hostname, device name, or Device ID is never sufficient proof of identity.

Workflow state is independent of network connectivity. A temporary phone or network failure must not terminate an AI agent session.

The user interacts with workflows rather than raw operating-system processes.

Provider-specific behavior remains inside provider adapters.

The mobile application remains a thin client. Heavy execution remains on the computer.

---

# 8. System Architecture

Calcar consists of four logical layers: the Mobile Application, the Calcar Backend, the Calcar Agent, and the development workloads running on the computer.

The Mobile Application provides the user interface and user-side security functions.

The Backend provides the control plane for identity, device registration, pairing coordination, connection coordination, notifications, and optional relay services.

The Calcar Agent provides the execution plane on the Windows computer.

AI agents and other development workloads remain on the computer.

The architecture is:

```text
                    ┌──────────────────────┐
                    │    Calcar Mobile     │
                    │                      │
                    │ Flutter / Dart       │
                    │ UI / Commands        │
                    │ Approvals            │
                    │ Notifications        │
                    └──────────┬───────────┘
                               │
                         HTTPS / WebSocket
                               │
                    ┌──────────▼───────────┐
                    │    Calcar Backend    │
                    │                      │
                    │ Go                   │
                    │ Auth / Devices       │
                    │ Pairing / Trust      │
                    │ Relay / Connections  │
                    └──────────┬───────────┘
                               │
                         Private Network
                       / authenticated relay
                               │
                    ┌──────────▼───────────┐
                    │    Calcar Agent      │
                    │      Windows         │
                    │                      │
                    │ Rust                 │
                    │ Identity             │
                    │ Trust                │
                    │ Workflows            │
                    │ Sessions             │
                    │ Providers            │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
        ┌─────▼─────┐    ┌─────▼─────┐    ┌────▼─────┐
        │ AI Agents │    │ Scripts /  │    │ Training │
        │           │    │ Builds     │    │ Jobs     │
        └───────────┘    └────────────┘    └──────────┘
```

The Backend is the control plane.

The Windows Agent is the execution plane.

The phone is the user interface and trust authority.

---

# 9. Technology Stack

## 9.1 Mobile Application

The mobile application will use **Flutter and Dart**.

Flutter provides a shared Android and iOS implementation while allowing native platform integration where required.

The mobile application will use **Riverpod** for application state management.

The mobile application will use platform security services for sensitive credentials. Android will use the Android Keystore. iOS will use Keychain and Secure Enclave capabilities where appropriate.

The application should avoid unnecessary background processing so that older phones can run Calcar with low battery and memory usage.

---

## 9.2 Windows Agent

The Windows Agent will use **Rust**.

Rust is responsible for the long-running computer-side component because the Agent requires low resource usage, operating-system integration, process management, terminal handling, networking, persistent sessions, and security-sensitive device operations.

The Agent will run as a Windows background service or equivalent background component.

The Agent will contain the device identity, trust, workflow, session, provider, event, input, permission, and connection subsystems.

---

## 9.3 Backend

The Calcar Backend will use **Go**.

Go will provide the HTTP API, WebSocket infrastructure, authentication services, device registry, pairing coordination, trust and revocation state, connection management, notification coordination, and future relay services.

The backend should remain small and service-oriented. Calcar does not require a large application framework for its initial architecture.

The backend must not become the execution environment for user development workloads.

---

## 9.4 Database

The primary backend database will be **PostgreSQL**.

PostgreSQL will store persistent control-plane information such as user identities, trusted devices, managed computers, public keys, pairing metadata, device state, and revocation records.

Project files, large terminal logs, and AI-agent execution data should not be stored in PostgreSQL by default.

---

## 9.5 Cache and Ephemeral State

Calcar will use **Redis** for short-lived state.

Redis can store pairing sessions, temporary connection information, presence data, short-lived approval state, and other data that does not require long-term persistence.

Pairing sessions must expire automatically.

---

## 9.6 Communication Protocol

Calcar will use **Protocol Buffers** for typed communication messages.

The protocol will define common structures for devices, workflows, events, commands, approvals, sessions, and connection state.

Protocol definitions will be maintained separately from the mobile and Agent implementations so that the phone, backend, and Agent can share a versioned communication contract.

---

## 9.7 Realtime Communication

**WebSockets** will provide realtime communication for workflow events, agent output, commands, approval responses, and connection state.

The mobile application should establish a live connection when the user is actively viewing or controlling a workflow.

The system should avoid maintaining unnecessary high-frequency connections while the application is idle.

---

## 9.8 Network Connectivity

Calcar should use private networking such as **Tailscale or WireGuard** for direct connectivity where practical.

The first implementation should avoid requiring users to expose public SSH ports.

A future Calcar relay can provide connectivity when direct private networking is unavailable.

SSH may be supported as an administrative or transport mechanism, but it should not be the basis of the product's trust model.

---

## 9.9 Notifications

Android notifications will use **Firebase Cloud Messaging**.

iOS notifications will use **Apple Push Notification service**.

Push notifications should contain minimal sensitive information. The mobile application should retrieve the complete approval or workflow information through an authenticated connection.

---

## 9.10 Local Storage

The Windows Agent will use **SQLite** for local persistent state.

The mobile application may also use SQLite or an equivalent local database for cached workflow state and local application data.

The Agent should retain enough state to reconstruct workflow status after a connection interruption or Agent restart.

Large logs should not be retained indefinitely in the main database.

---

## 9.11 Deployment

The backend should initially be deployed using **Docker** on a Linux server or cloud environment.

A reverse proxy such as **Caddy** or an equivalent edge service can terminate external HTTPS traffic.

GitHub Actions can provide CI/CD.

Kubernetes is not required for the MVP and should not be introduced until operational scale requires it.

---

# 10. Backend Architecture

The backend is a control-plane service.

It should provide authentication and identity management, device registration, pairing coordination, trusted-device state, revocation state, WebSocket connection management, notification coordination, and optional relay functionality.

The backend must not own the user's development environment.

A computer's project files, terminal sessions, AI-agent processes, and training jobs remain on that computer.

The backend may know that a workflow exists and may coordinate its connection, but it should not need to understand every command executed inside the workflow.

This separation allows the system to scale without turning the backend into a central execution bottleneck.

---

# 11. Backend Data Model

The backend should maintain records for users, trusted mobile devices, managed computers, public keys, trust relationships, pairing sessions, revocations, and relevant connection metadata.

The conceptual model is:

```text
User
 │
 ├── Owner Device
 │
 ├── Trusted Phones
 │
 └── Managed Computers
        │
        ├── Workflows
        ├── Sessions
        └── Provider state
```

The backend stores the control-plane representation.

The Agent stores the execution-plane representation.

---

# 12. First Pairing and Trust Bootstrap

The first pairing process is a core security requirement.

A laptop cannot be the root of trust because the laptop may already be compromised.

If an attacker controls the laptop, they can run the RemoteDev or Calcar pairing command, generate pairing information, display QR codes, and imitate local interfaces.

Therefore, a pairing protocol that begins with the computer generating a QR code and asking the phone to approve it does not provide an independent trust anchor.

Calcar instead makes the phone the authority.

The phone begins the pairing process. It creates a temporary pairing session and displays a QR code.

The computer scans the QR code.

The computer generates its own asymmetric keypair.

The private key remains on the computer.

The computer submits a join request associated with the phone-created pairing session.

The phone receives the request and displays the computer information.

The user explicitly approves or rejects the computer.

The authorization is cryptographically tied to the exact computer public key, pairing session, Owner identity, and authorization context.

The pairing session is short-lived and single-use.

The QR code is therefore a temporary pairing-session mechanism. It is not the root of trust.

---

# 13. First Pairing User Experience

The user installs Calcar on the phone.

The user establishes the Owner identity and secures the application with device authentication.

The user selects **Add Computer**.

Calcar creates a temporary pairing session and displays a QR code.

The user starts the Calcar Agent setup on Windows and scans the QR code.

The computer generates its device identity and submits the join request.

The phone displays:

```text
New computer wants to join Calcar

Computer: Narayan-PC
Device ID: RD-WIN-7F32...
Fingerprint: A91C 7D24 ...
Requested: Just now

[ Reject ]       [ Approve ]
```

The user selects **Approve**.

The computer becomes trusted and appears under **My Computers**.

---

# 14. Security Property of First Pairing

The following rule is a permanent system invariant:

**A computer must never be able to authorize a new phone by itself.**

An attacker controlling a computer may generate arbitrary join requests, but those requests must remain untrusted until the Owner Device approves them.

The computer fingerprint is useful for identification. It is not the root of trust.

---

# 15. Device Identity

Every managed computer must have a unique cryptographic identity.

The computer generates an asymmetric keypair during registration.

The private key remains on the computer.

The public key becomes part of the computer's registered identity.

The Device ID identifies the device but is not a secret.

A human-readable fingerprint should be available during pairing.

The computer identity should survive normal Agent restarts.

Where available, Windows DPAPI and TPM-backed capabilities should be used to protect the computer's private credentials.

---

# 16. Owner Device Security

The Owner Device holds the most sensitive user-side cryptographic identity.

The Owner private key must not leave the phone.

The key should use Android Keystore or iOS Keychain/Secure Enclave capabilities where available.

Normal application opening should use the phone's biometric or device authentication.

Sensitive operations should require stronger re-authentication. These operations include adding trusted phones, changing recovery configuration, transferring ownership, and other actions that modify the trust hierarchy.

The product should not require several authentication steps for ordinary workflow monitoring.

---

# 17. Additional Trusted Phones

The Owner Device can authorize another phone.

The new phone receives its own device identity and cryptographic credentials.

The new phone does not automatically become the Owner Device.

The system should record which trusted authority authorized the device.

A computer cannot add a phone to the trusted-device set.

---

# 18. Recovery

Calcar requires a recovery mechanism for loss of the Owner Device.

Recovery material must be generated outside the computer trust boundary.

The recovery credential must not exist only on the Windows computer.

Recovery should allow the user to establish a replacement Owner Device and revoke the lost device.

Recovery credentials must be treated as highly sensitive trust material.

---

# 19. Device Revocation

The Owner Device must be able to revoke a phone or computer.

Revocation must be part of the trust state and not only a local UI action.

Future connections from a revoked device must be rejected.

Revocation state should propagate to other trusted devices when connectivity is available.

A revoked computer may continue running local operating-system processes. It simply loses authorized Calcar access.

---

# 20. Workflow Model

A workflow is the primary user-facing unit.

A workflow represents a meaningful development activity and can contain many operating-system processes.

For example, an OpenCode workflow may contain OpenCode, shells, Git commands, package managers, compilers, and test runners.

The user sees one workflow.

The internal process tree remains an Agent implementation detail unless the user explicitly requests deeper diagnostic information.

A workflow may be running, waiting for input, waiting for approval, completed, failed, stopped, or temporarily disconnected from the phone while continuing to run.

---

# 21. Provider Adapter Architecture

Each AI provider can have a different command interface, session system, approval model, and output format.

Calcar therefore uses provider adapters.

The adapter converts provider-specific behavior into the common Calcar workflow model.

The common event model should support events such as agent started, command started, command completed, file changed, approval required, user input required, error occurred, workflow completed, and workflow stopped.

The provider adapter should expose only the capabilities that the provider supports.

---

# 22. Supported AI Providers

The initial architecture should support providers such as OpenCode, Claude Code, and Codex.

Each provider should be integrated through its own adapter.

Adding a provider should not require redesigning the mobile interface.

The adapter API should allow future AI coding agents to integrate with the same workflow model.

---

# 23. Persistent Sessions

AI sessions remain on the computer.

Closing the phone application, losing network connectivity, or temporarily losing the connection to the computer must not terminate a workflow.

The Calcar Agent maintains the relationship between a workflow and its underlying provider session.

When the phone reconnects, it retrieves the current workflow state and relevant event history.

The user continues the existing session.

---

# 24. Workflow Commands

The mobile application must allow users to send natural-language instructions to supported AI workflows.

Examples include:

```text
Start Phase 2.
Run the tests.
Continue.
Stop.
What are you doing?
Do not modify the payment code.
```

The Agent routes the instruction to the correct workflow and provider adapter.

Destructive or high-impact actions may require explicit confirmation.

---

# 25. Approval Handling

Approval requests are a core feature.

When an AI provider requires approval, the provider adapter converts the request into a Calcar approval event.

The phone displays the request.

For example:

```text
Claude Code needs approval

Command:
npm install stripe

[ Reject ]       [ Allow ]
```

The response is associated with the exact workflow, session, approval request, and trusted device.

Expired or already-resolved approval requests cannot be accepted again.

---

# 26. Main Mobile Screen

The primary screen should be simple.

The user sees **My Computers**.

Each computer shows its connection state and active workflows.

Example:

```text
My Computers

Narayan-PC
● Online

Claude Code
Implement authentication
Waiting for approval

OpenCode
Refactor API layer
Running

Python Training
Astra pretraining
Running
```

The process tree is hidden by default.

---

# 27. Computer Screen

Selecting a computer opens its detail screen.

The screen shows connection state and active workflows.

Optional system information can include CPU, RAM, GPU, disk, and similar resource data.

System information remains secondary to workflow state.

The user can access computer-level actions such as workflow management, device information, and revocation where authorized.

---

# 28. Workflow Screen

The workflow screen should provide several views.

The **Chat** view provides interaction with the AI agent.

The **Activity** view provides important workflow events.

The **Terminal** view provides deeper terminal output when supported.

The **Files/Diff** view provides relevant project changes when supported.

The default view should prioritize useful events rather than overwhelming the user with raw logs.

---

# 29. Notifications

Calcar should notify users when a workflow requires attention.

Important notification types include approval requests, workflow completion, workflow failure, user-input requests, significant errors, and connection problems.

Each notification should identify the computer and workflow.

The notification should avoid exposing unnecessary source code, terminal output, or project content.

---

# 30. Windows Agent Architecture

The Agent is divided into logical modules.

The **Device Identity Manager** handles computer identity and key management.

The **Trust Manager** handles trusted-device authorization and revocation.

The **Workflow Manager** handles workflow creation, lifecycle, and state.

The **Session Manager** maintains provider sessions across phone connections.

The **Provider Adapters** integrate AI coding agents.

The **Event Stream** converts workflow activity into Calcar events.

The **Input Router** routes commands to the correct workflow.

The **Permission Manager** handles approval requests and sensitive operations.

The **Connection Manager** maintains authenticated communication.

The **Storage Layer** maintains durable local state.

---

# 31. Terminal and Process Management

The Agent should use a proper terminal or pseudo-terminal abstraction for interactive AI coding tools.

The system must support interactive input and output rather than treating every AI agent as a simple one-shot command.

The conceptual execution path is:

```text
Calcar Agent
      │
      ▼
PTY / Process Manager
      │
      ▼
AI Agent
      │
 ┌────┼────┐
 ▼    ▼    ▼
out  err  input
```

The Agent should manage process groups and workflow lifecycle without exposing implementation-level process details to the normal mobile interface.

---

# 32. Communication Security

All Calcar control traffic must be authenticated and encrypted.

A network attacker must not be able to read workflow commands, approval responses, or sensitive workflow traffic.

A network attacker must not be able to authenticate as a trusted phone or computer.

The protocol must include replay protection.

Pairing requests must expire.

Sensitive requests should contain unique request identifiers and should be rejected when reused.

---

# 33. Cryptographic Architecture

Calcar must use established cryptographic libraries rather than implementing cryptographic primitives directly.

The architecture requires asymmetric device identity, authenticated key exchange, encrypted communication, signed authorization records, replay protection, expiry, and revocation.

Ed25519-style signing keys and X25519-style key exchange are candidate primitives for the design.

The final security design must define exact algorithms, message formats, key storage, key rotation, session establishment, authorization, and revocation.

Private keys must remain inside their owning security boundary.

---

# 34. Threat Model

Calcar considers a network attacker, an attacker with physical access to a computer, an attacker with administrative or full operating-system access to the computer, a stolen-phone attacker, and an attacker attempting to replay an old pairing message.

The most important security limitation is a fully compromised computer.

If an attacker has complete operating-system control, they may modify the Agent, manipulate workflow state, or interfere with local execution.

Calcar therefore protects the phone-side trust authority while treating the computer as an endpoint that cannot be assumed trustworthy after full compromise.

---

# 35. Security Guarantees

Knowledge of a Device ID is never sufficient for authentication.

A computer cannot authorize a new phone without Owner authorization.

An unknown phone cannot become trusted merely because it can communicate with a computer.

Old pairing requests cannot remain valid indefinitely.

Network attackers cannot authenticate without valid cryptographic credentials.

Revoked devices cannot establish authorized sessions.

The Owner private key never leaves the Owner Device.

---

# 36. Security Non-Guarantees

Calcar cannot guarantee the integrity of a fully compromised computer.

Calcar cannot prevent a user from approving a malicious device or command.

Calcar cannot protect against simultaneous full compromise of both the Owner Device and the computer.

Calcar cannot protect recovery credentials after deliberate exposure by the user.

---

# 37. Privacy and Data Handling

Calcar should minimize data stored outside the user's devices.

Workflow output, project information, file changes, AI conversations, and terminal information should remain on the user's computer unless a cloud feature explicitly requires otherwise.

If a Calcar relay is introduced, the product must define which data passes through the relay and how end-to-end encryption is maintained.

Private keys must never be stored as ordinary plaintext application data.

Calcar should not collect source code, terminal history, or AI conversations as telemetry.

---

# 38. Old Phone and Resource Requirements

Calcar is intentionally designed as a thin mobile client.

The phone does not run AI models or development workloads.

The computer performs the CPU- and GPU-intensive work.

The mobile application primarily renders workflow state, text, terminal output, diffs, notifications, and controls.

A reasonable initial design target is approximately 80–200 MB of foreground RAM during normal use, with lower usage while idle. The final resource requirements must be measured on real devices.

The application should avoid unnecessary background polling and should use push notifications for important events.

The mobile application should use bounded event and terminal buffers so that long-running workflows do not cause unbounded memory growth.

The application should support older phones that meet the minimum supported Android or iOS version and security requirements.

A dedicated old phone should be able to operate using Wi-Fi without requiring a SIM card.

---

# 39. Phone Connectivity Requirements

Calcar requires a network path between the phone and computer.

The phone does not specifically require Wi-Fi. Mobile data can be used when remote connectivity is available.

Wi-Fi is sufficient for a dedicated phone.

Bluetooth is not required for normal Calcar operation.

NFC is not required.

Bluetooth or NFC may be considered for future local pairing convenience, but neither can replace cryptographic authorization.

The camera is useful for QR-based pairing.

GPS is not required.

---

# 40. Reliability Requirements

A temporary network failure must not terminate a workflow.

Closing the mobile application must not terminate a workflow.

Restarting the mobile application must allow recovery of workflow state.

Restarting the Agent should recover durable workflow information where possible.

The application must distinguish between an inactive workflow and a disconnected phone.

A workflow must not be marked completed simply because the phone disconnected.

---

# 41. Performance Requirements

The main computer screen should load quickly after authentication.

Workflow events should reach the phone with low delay under normal network conditions.

Approval notifications should be delivered promptly within the limits of the mobile notification systems.

The Agent should use minimal CPU and memory while idle.

The Agent must not significantly interfere with AI inference, training, compilation, testing, or other development workloads.

The mobile application should remain responsive while receiving terminal and workflow events.

---

# 42. Device Management

The application provides a device-management interface.

Users can view trusted phones and managed computers.

Each device has a human-readable name, Device ID, device type, connection state, and last-seen information.

The Owner Device is clearly identified.

Authorized users can revoke devices.

Sensitive device-management operations require application authentication.

---

# 43. User Lifecycle

The user installs Calcar on the phone.

The user establishes the Owner identity.

The user secures the application.

The user selects Add Computer.

The phone creates the pairing session.

The computer joins the session and creates its identity.

The phone receives the join request.

The user approves the computer.

The computer becomes trusted.

The user starts or connects to a workflow.

The workflow runs on the computer.

The phone receives workflow events.

The user sends instructions or handles approvals.

The phone may disconnect.

The workflow continues.

The phone reconnects and restores the existing workflow state.

---

# 44. MVP Scope

The MVP should support one Owner Device and at least one Windows computer.

It should provide secure device identity, phone-authorized first pairing, trusted-device management, revocation, authenticated connectivity, workflow monitoring, persistent sessions, AI provider integration, natural-language commands, approval handling, notifications, and reconnect behavior.

The initial AI provider integrations should target OpenCode, Claude Code, and Codex where their interfaces support the required capabilities.

Generic command workflows should be supported where practical.

Cloud relay functionality can remain limited or optional in the first release if private networking provides the required connectivity.

---

# 45. Future Scope

Future versions may support macOS and Linux computers.

Additional AI coding agents can be added through provider adapters.

A Calcar relay can provide connectivity when direct private networking is unavailable.

The system may support shared computers and team access.

Role-based permissions may introduce administrators, operators, and observers.

Calcar may add richer Git integration, workflow templates, resource monitoring, workflow analytics, and AI-agent policy controls.

---

# 46. Deployment and Operations

The backend should initially run as a small set of containerized services.

The first deployment can use:

```text
Docker
  │
  ├── Calcar API
  ├── PostgreSQL
  └── Redis
```

An external edge service can provide HTTPS termination and traffic protection.

The system should include structured logging, health checks, metrics, and error reporting.

OpenTelemetry can provide tracing and metrics instrumentation.

A monitoring stack such as Grafana and Loki can be introduced as operational requirements grow.

---

# 47. Success Metrics

The primary success measure is whether users can manage long-running development work without returning to their computer for routine monitoring and control.

First-computer pairing success should measure how many new users successfully add a computer.

Reconnect reliability should measure whether existing workflows remain accessible after phone disconnection.

Approval delivery reliability should measure how often approval requests reach the phone.

Command delivery success should measure whether mobile commands reach the intended workflow.

Security success should include zero cases where an untrusted phone becomes authorized solely through control of a managed computer.

Resource efficiency should measure mobile memory, CPU, battery, and network usage across supported devices.

---

# 48. Acceptance Criteria

The MVP is acceptable only if a new user can install Calcar, establish an Owner Device, and securely add a Windows computer.

A computer controlled by an attacker must not be able to authorize that attacker's phone without Owner approval.

A pairing request must expire and cannot be reused after completion or rejection.

The phone must show sufficient computer identity information for the user to understand the device being approved.

The computer must maintain its own cryptographic identity.

The Owner private key must never be stored on the computer.

A trusted computer must appear in the mobile application.

The user must be able to view active workflows.

A workflow must continue running when the phone disconnects.

The user must be able to reconnect to the existing workflow.

The user must be able to send instructions to a supported AI agent.

AI approval requests must appear on the phone.

The user must be able to approve or reject an approval request.

A revoked device must lose Calcar authorization.

A network attacker must not be able to authenticate as a trusted device.

The mobile application must not require the user to manage individual Windows child processes during normal operation.

The mobile client must remain usable on older supported phones within the defined resource targets.

---

# 49. Key Product Invariants

The phone is the initial trust authority.

The first trusted phone is the Owner Device.

A computer requests authorization.

A computer cannot authorize itself.

A QR code establishes a temporary pairing session. It does not establish trust by itself.

Device IDs identify devices. They do not authenticate devices.

Private keys never leave their owning security boundary.

Network location does not establish identity.

A phone disconnect does not terminate a workflow.

A workflow is the user-facing abstraction over potentially many operating-system processes.

Provider-specific behavior belongs inside provider adapters.

The Backend is the control plane.

The Windows Agent is the execution plane.

The mobile application is a thin client.

A fully compromised computer cannot be treated as trustworthy.

---

# 50. Open Technical Decisions

The final cryptographic protocol must define algorithms, message formats, key rotation, authorization records, revocation, session establishment, and recovery.

The network architecture must define when Calcar uses direct private networking, SSH, or a Calcar relay.

The product must decide whether an account or cloud identity is required for initial Owner establishment.

The recovery system must define credential generation, storage, rotation, and replacement.

The provider adapter API must define the common workflow events and provider capabilities.

The workflow persistence layer must define which state belongs to Calcar and which state remains owned by the underlying AI provider.

The minimum supported Android and iOS versions must be selected based on security requirements and the goal of supporting older phones.

---

# 51. Final Product Architecture

Calcar uses a thin-client architecture.

Flutter provides the mobile interface.

Go provides the backend control plane.

Rust provides the Windows execution plane.

PostgreSQL stores persistent backend control-plane state.

Redis stores short-lived backend state.

Protocol Buffers define communication structures.

WebSockets provide realtime application communication.

Tailscale or WireGuard provides private connectivity where direct networking is available.

FCM and APNs provide mobile notifications.

Android Keystore, iOS Keychain/Secure Enclave, Windows DPAPI, and TPM capabilities protect device credentials.

The resulting architecture is:

```text
                         CALCAR
                            │
              ┌─────────────┴─────────────┐
              │                           │
           MOBILE                       SERVER
           Flutter                        Go
             │                           │
           Dart                      HTTP / WS
             │                           │
         Riverpod                   PostgreSQL
             │                        Redis
       Keystore/Keychain                  │
              │                           │
              └─────────────┬─────────────┘
                            │
                  authenticated network
                            │
                            ▼
                       WINDOWS PC
                            │
                         Rust Agent
                            │
       ┌────────────────────┼────────────────────┐
       │                    │                    │
    OpenCode              Claude               Codex
       │                    │                    │
       └────────────────────┼────────────────────┘
                            │
                  Other workflows
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
           Python         Docker        Builds
           Training       Jobs          Tests
```

The core architectural separation is:

**Flutter = interface**

**Go = control plane**

**Rust = execution plane**

**AI agents and development tools = actual work**

This separation keeps the phone lightweight, keeps the backend scalable, and keeps computer-side execution independent from mobile connectivity.

The trust model remains independent from all three execution layers: the Owner Device is the authority that decides which computers and phones are trusted.