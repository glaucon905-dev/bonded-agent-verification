# EIP-XXXX: Bonded Agent Verification

## Abstract

This proposal defines a standard for verifiable off-chain agent execution using cryptographic commitments and economic bonds. Agents commit to a specific model configuration before execution, bond capital on their outputs, and face slashing if challengers prove incorrect execution. This enables trustless verification of AI agent behavior without requiring on-chain execution or zero-knowledge proofs.

## Motivation

AI agents increasingly operate autonomously—executing trades, managing infrastructure, and making decisions with real economic consequences. Current trust models rely on:

1. **Reputation systems** — Retrospective and gameable. A 5-star agent can still rug the next request.
2. **TEE attestation** — Requires trusting hardware vendors (Intel, AMD, ARM).
3. **zkML proofs** — Computationally expensive and limited to small models.

None of these provide **economic finality** — a guarantee that incorrect behavior results in financial loss.

This EIP introduces **Bonded Agent Verification**: agents stake capital on the correctness of their outputs. Anyone can challenge by re-executing the computation. The chain arbitrates disputes and slashes the losing party.

### Design Goals

1. **Deterministic specification** — Model, config, and skills are committed before execution
2. **Economic security** — Bonds scale with value at risk
3. **Permissionless challenges** — Anyone can dispute, not just the client
4. **Composable** — Works with ERC-8004 identity or standalone

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119.

### Core Concepts

#### Agent Specification

An agent is defined by its **Agent Spec**, a deterministic description of its capabilities:

```solidity
struct AgentSpec {
    bytes32 modelHash;        // keccak256(model_weights) or IPFS CID
    bytes32 configHash;       // keccak256(inference_config)
    bytes32 skillsRoot;       // Merkle root of available skills/tools
    uint64 maxTokens;         // Maximum output tokens
    uint8 temperature;        // 0-100 (0 = deterministic)
    uint8 topP;               // 0-100 (nucleus sampling)
    uint64 randomSeed;        // For reproducibility when temperature > 0
}
```

**Model Hash**: For open-weight models (Llama, Mistral, etc.), this is `keccak256(weights)`. For hosted models, this is a provider-attested identifier (e.g., `keccak256("openai:gpt-4-0125-preview")`).

**Config Hash**: Captures all inference parameters that affect output:
```json
{
  "temperature": 0,
  "top_p": 1.0,
  "max_tokens": 4096,
  "stop_sequences": ["\n\n"],
  "system_prompt_hash": "0x..."
}
```

**Skills Root**: Merkle root of the agent's available tools/skills:
```
skills_root = merkle_root([
  keccak256("web_search"),
  keccak256("code_execution"),
  keccak256("file_read"),
  ...
])
```

This allows verifiers to confirm the agent had access to specific skills without revealing the full list.

#### Task Lifecycle

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  COMMITTED  │────▶│  EXECUTED   │────▶│ CHALLENGED  │────▶│  RESOLVED   │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │                   │
      │ Agent bonds       │ Output published  │ Challenger bonds  │ Winner paid
      │ Input committed   │ Challenge window  │ Evidence submitted│ Loser slashed
```

**States:**
- `COMMITTED` — Task created, input hashed, agent bonded
- `EXECUTED` — Output published, challenge window open
- `CHALLENGED` — Active dispute, awaiting resolution
- `RESOLVED` — Final state, bonds distributed

### Registry Interface

```solidity
interface IBondedAgentRegistry {
    
    /// @notice Register an agent with its specification
    /// @param spec The agent's deterministic specification
    /// @param metadataURI IPFS/HTTPS link to full agent metadata
    /// @return agentId Unique identifier for the agent
    function registerAgent(
        AgentSpec calldata spec,
        string calldata metadataURI
    ) external returns (uint256 agentId);
    
    /// @notice Update agent specification (resets reputation)
    function updateAgentSpec(
        uint256 agentId,
        AgentSpec calldata newSpec
    ) external;
    
    /// @notice Get agent specification
    function getAgentSpec(uint256 agentId) external view returns (AgentSpec memory);
}
```

### Task Interface

```solidity
interface IBondedTaskManager {
    
    struct Task {
        uint256 agentId;
        bytes32 inputHash;          // keccak256(input)
        bytes32 outputHash;         // keccak256(output), set after execution
        uint256 agentBond;          // Amount bonded by agent
        uint256 challengerBond;     // Amount bonded by challenger (if any)
        address challenger;         // Challenger address (if any)
        uint64 executedAt;          // Timestamp of output publication
        uint64 challengeDeadline;   // End of challenge window
        TaskState state;
    }
    
    enum TaskState {
        COMMITTED,
        EXECUTED,
        CHALLENGED,
        RESOLVED_AGENT_WON,
        RESOLVED_CHALLENGER_WON,
        RESOLVED_NO_CHALLENGE
    }
    
    /// @notice Submit a task for execution
    /// @param agentId The agent to execute the task
    /// @param inputHash keccak256 of the input prompt/data
    /// @param inputURI Where to fetch the actual input
    /// @param fee Payment to agent for execution
    /// @return taskId Unique task identifier
    function submitTask(
        uint256 agentId,
        bytes32 inputHash,
        string calldata inputURI,
        uint256 fee
    ) external payable returns (uint256 taskId);
    
    /// @notice Agent bonds and commits to execute
    /// @param taskId The task to execute
    /// @param bondAmount Amount to bond (must meet minimum)
    function bondTask(
        uint256 taskId,
        uint256 bondAmount
    ) external payable;
    
    /// @notice Publish execution result
    /// @param taskId The executed task
    /// @param outputHash keccak256 of the output
    /// @param outputURI Where to fetch the actual output
    /// @param executionProof Optional proof (zkML, TEE attestation, etc.)
    function publishResult(
        uint256 taskId,
        bytes32 outputHash,
        string calldata outputURI,
        bytes calldata executionProof
    ) external;
    
    /// @notice Challenge a result
    /// @param taskId The task to challenge
    /// @param claimedCorrectOutputHash The challenger's computed output hash
    /// @param evidenceURI Proof of re-execution
    function challenge(
        uint256 taskId,
        bytes32 claimedCorrectOutputHash,
        string calldata evidenceURI
    ) external payable;
    
    /// @notice Resolve a challenge (can be called by anyone after deadline)
    /// @param taskId The task to resolve
    /// @param arbitrationData Data from arbitrator (if using external arbitration)
    function resolve(
        uint256 taskId,
        bytes calldata arbitrationData
    ) external;
    
    /// @notice Claim bonds after resolution (no challenge case)
    function claimBonds(uint256 taskId) external;
}
```

### Skill Verification

Skills are the tools/functions an agent can invoke. They MUST be committed upfront to prevent agents from claiming they "couldn't" perform an action.

```solidity
interface ISkillRegistry {
    
    struct Skill {
        bytes32 skillHash;        // keccak256(skill_definition)
        string name;              // Human-readable name
        string specURI;           // Link to full specification
        bool isDeterministic;     // Whether outputs are reproducible
    }
    
    /// @notice Register a skill definition
    function registerSkill(
        string calldata name,
        string calldata specURI,
        bool isDeterministic
    ) external returns (bytes32 skillHash);
    
    /// @notice Verify a skill is in an agent's skill tree
    function verifySkill(
        bytes32 skillsRoot,
        bytes32 skillHash,
        bytes32[] calldata merkleProof
    ) external pure returns (bool);
}
```

**Skill Definition Schema:**
```json
{
  "name": "web_search",
  "version": "1.0.0",
  "description": "Search the web using Brave API",
  "inputs": {
    "query": "string",
    "count": "uint8"
  },
  "outputs": {
    "results": "SearchResult[]"
  },
  "deterministic": false,
  "side_effects": ["network_request"]
}
```

### Bond Economics

#### Minimum Bond Calculation

```solidity
function calculateMinBond(
    uint256 taskValue,      // Economic value at risk
    uint256 agentReputation,// Historical success rate (0-10000 bps)
    uint256 modelComplexity // Proxy for verification cost
) public pure returns (uint256) {
    // Base: 10% of task value
    uint256 baseBond = taskValue / 10;
    
    // Reputation discount: up to 50% off for perfect reputation
    uint256 reputationMultiplier = 10000 - (agentReputation / 2);
    
    // Complexity premium: higher for harder-to-verify models
    uint256 complexityMultiplier = 10000 + modelComplexity;
    
    return (baseBond * reputationMultiplier * complexityMultiplier) / 100000000;
}
```

#### Challenger Bond Requirement

Challengers MUST bond more than the agent to prevent griefing:

```solidity
uint256 constant CHALLENGER_BOND_MULTIPLIER = 150; // 1.5x agent bond

function getRequiredChallengerBond(uint256 agentBond) public pure returns (uint256) {
    return (agentBond * CHALLENGER_BOND_MULTIPLIER) / 100;
}
```

#### Slashing Distribution

On resolution:
- **No challenge**: Agent reclaims bond + earns fee
- **Agent wins**: Agent gets own bond + challenger's bond (minus protocol fee)
- **Challenger wins**: Challenger gets own bond + agent's bond (minus protocol fee)

```solidity
uint256 constant PROTOCOL_FEE_BPS = 500; // 5% to protocol treasury

function distributeSlashing(
    uint256 winnerBond,
    uint256 loserBond,
    address winner
) internal {
    uint256 protocolFee = (loserBond * PROTOCOL_FEE_BPS) / 10000;
    uint256 winnerPayout = winnerBond + loserBond - protocolFee;
    
    payable(winner).transfer(winnerPayout);
    payable(protocolTreasury).transfer(protocolFee);
}
```

### Deterministic Model Specification

For verifiable re-execution, models MUST be specified deterministically.

#### Open-Weight Models

```json
{
  "type": "open-weights",
  "framework": "transformers",
  "model_id": "meta-llama/Llama-3.1-70B-Instruct",
  "weights_hash": "0x...",           // keccak256 of safetensors
  "tokenizer_hash": "0x...",         // keccak256 of tokenizer.json
  "quantization": "none",            // or "int8", "int4", etc.
  "inference_config": {
    "temperature": 0,
    "top_p": 1.0,
    "max_new_tokens": 4096,
    "do_sample": false,
    "seed": 42
  }
}
```

#### Hosted/Proprietary Models

```json
{
  "type": "hosted",
  "provider": "openai",
  "model": "gpt-4-0125-preview",
  "api_version": "2024-01-25",
  "config": {
    "temperature": 0,
    "max_tokens": 4096,
    "seed": 42
  },
  "attestation": {
    "type": "provider-signed",
    "signature": "0x...",
    "timestamp": 1707350400
  }
}
```

**Note**: Hosted models require provider cooperation for verification. The provider SHOULD:
1. Support deterministic outputs (`seed` parameter)
2. Sign attestations of model version and config
3. Optionally provide TEE attestation

### Challenge Resolution

#### Resolution Methods

1. **Re-execution** (default for open models)
   - Challenger re-runs inference with committed config
   - Outputs compared via hash
   - Deterministic models: exact match required
   - Non-deterministic: semantic similarity threshold

2. **Arbitration** (for proprietary or complex cases)
   - Designated arbitrator contract/DAO
   - Reviews evidence from both parties
   - Majority vote or expert judgment

3. **TEE Verification**
   - Agent provides TEE attestation
   - Verifier checks attestation validity
   - Code hash must match committed agent spec

4. **zkML Proof**
   - Agent provides ZK proof of correct execution
   - Verifier validates proof on-chain
   - Currently limited to small models

```solidity
enum ResolutionMethod {
    RE_EXECUTION,
    ARBITRATION,
    TEE_ATTESTATION,
    ZKML_PROOF
}

interface IResolver {
    function resolve(
        uint256 taskId,
        bytes calldata agentEvidence,
        bytes calldata challengerEvidence
    ) external returns (address winner);
}
```

### Events

```solidity
event AgentRegistered(
    uint256 indexed agentId,
    address indexed owner,
    bytes32 modelHash,
    bytes32 skillsRoot
);

event TaskSubmitted(
    uint256 indexed taskId,
    uint256 indexed agentId,
    bytes32 inputHash,
    uint256 fee
);

event TaskBonded(
    uint256 indexed taskId,
    uint256 bondAmount
);

event ResultPublished(
    uint256 indexed taskId,
    bytes32 outputHash,
    string outputURI
);

event TaskChallenged(
    uint256 indexed taskId,
    address indexed challenger,
    bytes32 claimedOutputHash,
    uint256 challengerBond
);

event TaskResolved(
    uint256 indexed taskId,
    address indexed winner,
    uint256 payout,
    ResolutionMethod method
);
```

## Rationale

### Why Bonds Instead of Reputation?

Reputation is:
- **Retrospective**: Tells you about past behavior, not future
- **Gameable**: Sybil attacks, fake reviews, reputation farming
- **Non-binding**: No economic consequence for failure

Bonds are:
- **Prospective**: Capital at risk on THIS task
- **Self-selecting**: Only confident agents bond high
- **Economically binding**: Direct financial loss for misbehavior

### Why Commit Model Spec Upfront?

Without commitment, agents can claim post-hoc:
- "I used a different model version"
- "My config was different"
- "I didn't have access to that skill"

Upfront commitment creates a verifiable contract: "I will execute X with config Y and skills Z."

### Why Merkle Root for Skills?

- **Privacy**: Don't reveal full skill list
- **Efficiency**: O(log n) verification
- **Flexibility**: Prove specific skill access on demand

### Why Challenger Bonds 1.5x?

Prevents griefing attacks where challengers spam disputes to:
- Lock up agent capital
- Force agents to spend gas on resolution
- Damage reputation without real evidence

At 1.5x, challengers risk more than they can gain from frivolous challenges.

## Backwards Compatibility

This EIP is designed to complement ERC-8004:

- **Identity**: Use ERC-8004's Identity Registry for agent NFTs
- **Discovery**: Use ERC-8004's agentURI for metadata
- **Reputation**: OPTIONAL — can coexist or replace 8004's Reputation Registry
- **Validation**: IMPLEMENTS the validation interface from ERC-8004

Agents MAY register in both systems:
```json
{
  "registrations": [
    { "standard": "ERC-8004", "agentId": 42 },
    { "standard": "ERC-XXXX", "agentId": 7 }
  ]
}
```

## Security Considerations

### Griefing Attacks

**Attack**: Spam challenges to lock agent capital
**Mitigation**: Challenger bond > agent bond; loser pays gas

### Front-Running

**Attack**: See pending challenge, front-run with own challenge
**Mitigation**: Commit-reveal scheme for challenges

### Model Substitution

**Attack**: Agent commits to Model A, runs Model B
**Mitigation**: 
- For open models: Re-execution by challenger
- For hosted: Provider attestation + potential TEE

### Collusion

**Attack**: Agent and challenger collude to drain protocol fees
**Mitigation**: Protocol fee only on slashed amount; no profit from self-challenge

### Non-Determinism

**Attack**: Agent exploits randomness to generate favorable outputs
**Mitigation**: 
- Require temperature=0 for high-stakes tasks
- Commit random seed upfront
- Use semantic similarity for non-deterministic outputs

### Stale Model Hashes

**Attack**: Model weights update, hash becomes invalid
**Mitigation**: Include version/timestamp; require re-registration on updates

## Reference Implementation

See: [GitHub Gist - BondedAgentVerification.sol]

## Copyright

Copyright and related rights waived via CC0.
