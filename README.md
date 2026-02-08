# EIP-XXXX: Bonded Agent Verification

A proposal for verifiable off-chain AI agent execution using cryptographic commitments and economic bonds.

## Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Core Concepts](#core-concepts)
- [Parameter Reference](#parameter-reference)
- [Contracts](#contracts)
- [Tests](#tests)
- [Development](#development)
- [Security Considerations](#security-considerations)
- [References](#references)

---

## Overview

This EIP defines a standard for trustless AI agent verification. Unlike reputation-based systems (ERC-8004), this proposal uses **economic bonding** to ensure agents behave correctly:

1. **Agents commit** to a deterministic specification (model + config + skills)
2. **Agents bond capital** on their outputs
3. **Anyone can challenge** by re-executing and proving discrepancy
4. **Slashing** distributes bonds to the winning party

### Why Bonds Over Reputation?

| Approach | Retrospective | Gameable | Binding |
|----------|---------------|----------|---------|
| Reputation | ✅ Past only | ✅ Sybil attacks | ❌ No penalty |
| **Bonding** | ❌ This task | ❌ Capital at risk | ✅ Slashing |

---

## Repository Structure

```
├── EIP-XXXX-BondedAgentVerification.md  # Full EIP specification
├── README.md                             # This file
├── foundry.toml                          # Foundry configuration
├── contracts/
│   ├── BondedAgentRegistry.sol           # Agent registration with specs
│   ├── BondedTaskManager.sol             # Task lifecycle & bonding
│   └── SkillRegistry.sol                 # Skill definitions & Merkle proofs
└── test/
    ├── BondedAgentRegistry.t.sol         # Registry tests
    ├── BondedTaskManager.t.sol           # Task lifecycle tests
    └── SkillRegistry.t.sol               # Skill verification tests
```

---

## Core Concepts

### Agent Specification

Every agent commits to a deterministic specification **before** accepting tasks:

```solidity
struct AgentSpec {
    bytes32 modelHash;      // Unique model identifier
    bytes32 configHash;     // Inference configuration
    bytes32 skillsRoot;     // Merkle root of capabilities
    uint64 maxTokens;       // Output limit
    uint8 temperature;      // Randomness (0-100)
    uint8 topP;             // Nucleus sampling (0-100)
    uint64 randomSeed;      // For reproducibility
}
```

### Task Lifecycle

```
┌─────────┐    ┌───────────┐    ┌──────────┐    ┌────────────┐    ┌──────────┐
│ PENDING │───▶│ COMMITTED │───▶│ EXECUTED │───▶│ CHALLENGED │───▶│ RESOLVED │
└─────────┘    └───────────┘    └──────────┘    └────────────┘    └──────────┘
     │              │                │                │                │
     │         Agent bonds      Output hash      Challenger        Winner
     │                          published        bonds 1.5x         paid
     └─ Client submits                                              Loser
        with fee                                                   slashed
```

---

## Parameter Reference

### Model Configuration Parameters

Each parameter in `AgentSpec` directly affects model output. Below are detailed explanations with citations.

#### `temperature` (0-100, representing 0.0-1.0)

**What it does:** Controls randomness in token selection. Higher values = more random/creative outputs.

**How it works:** Temperature modifies the softmax probability distribution over the vocabulary:

```
P(token_i) = exp(logit_i / T) / Σ exp(logit_j / T)
```

Where `T` is temperature. As `T → 0`, the distribution becomes deterministic (argmax). As `T → ∞`, the distribution becomes uniform.

| Value | Behavior | Use Case |
|-------|----------|----------|
| 0 | Deterministic (greedy) | **Required for verifiable execution** |
| 0.1-0.3 | Low randomness | Factual Q&A |
| 0.7-0.9 | Moderate randomness | Creative writing |
| 1.0+ | High randomness | Brainstorming |

**Why it matters for verification:**
- `temperature=0` guarantees identical outputs for identical inputs
- Any `temperature>0` introduces non-determinism, making re-execution challenges probabilistic rather than exact

**References:**
- [OpenAI API Reference - Temperature](https://platform.openai.com/docs/api-reference/chat/create#chat-create-temperature)
- [Holtzman et al., "The Curious Case of Neural Text Degeneration" (2020)](https://arxiv.org/abs/1904.09751) - Section 2.1 on temperature scaling
- [Hugging Face - Generation Strategies](https://huggingface.co/docs/transformers/generation_strategies#temperature)

---

#### `topP` (0-100, representing 0.0-1.0)

**What it does:** Nucleus sampling - limits token selection to the smallest set whose cumulative probability ≥ `top_p`.

**How it works:**
1. Sort tokens by probability (descending)
2. Find smallest set where cumulative probability ≥ top_p
3. Renormalize probabilities over this set
4. Sample from reduced distribution

**Example:** If `top_p=0.9`, and the top 50 tokens cover 90% probability, only those 50 tokens are considered.

| Value | Behavior | Use Case |
|-------|----------|----------|
| 0.1 | Very focused (top tokens only) | Deterministic-ish |
| 0.5 | Moderate focus | Balanced generation |
| 0.9 | Wide focus (default) | General use |
| 1.0 | No filtering | Full vocabulary |

**Why it matters for verification:**
- `top_p=1.0` with `temperature=0` = fully deterministic
- Lower `top_p` values can still introduce variance when multiple tokens have similar probabilities

**References:**
- [Holtzman et al., "The Curious Case of Neural Text Degeneration" (2020)](https://arxiv.org/abs/1904.09751) - Section 4: Nucleus Sampling
- [OpenAI API Reference - top_p](https://platform.openai.com/docs/api-reference/chat/create#chat-create-top_p)
- [Google AI - Sampling Methods](https://ai.google.dev/gemini-api/docs/models/generative-models#model-parameters)

---

#### `maxTokens`

**What it does:** Limits the maximum number of tokens in the generated output.

**How it affects output:**
- Output is truncated if generation would exceed `maxTokens`
- Affects cost (most APIs charge per token)
- Can cause incomplete responses if set too low

| Model | Typical Max Context | Recommended Output Limit |
|-------|---------------------|--------------------------|
| GPT-4 Turbo | 128k | 4096 |
| Claude 3 | 200k | 4096 |
| Llama 3.1 70B | 128k | 4096 |

**Why it matters for verification:**
- Must match exactly between agent and challenger
- Different `maxTokens` can produce different outputs even with same input

**References:**
- [OpenAI API Reference - max_tokens](https://platform.openai.com/docs/api-reference/chat/create#chat-create-max_tokens)
- [Anthropic API Reference - max_tokens](https://docs.anthropic.com/en/api/messages)

---

#### `randomSeed`

**What it does:** Seeds the random number generator for reproducible sampling.

**How it works:**
- When `seed` is set, the model's RNG is initialized to that value
- Same seed + same input + same config = same output (usually)
- **Caveat:** Not all providers guarantee perfect reproducibility

**Provider support:**

| Provider | Seed Support | Determinism Guarantee |
|----------|--------------|----------------------|
| OpenAI | ✅ `seed` param | "Mostly deterministic" (their words) |
| Anthropic | ❌ Not supported | Use `temperature=0` |
| Google | ✅ `seed` param | Best-effort |
| Local (Llama.cpp) | ✅ Full control | Exact reproducibility |

**Why it matters for verification:**
- Essential for reproducible execution with `temperature>0`
- Commit seed upfront to prevent post-hoc manipulation

**References:**
- [OpenAI Blog - Reproducible Outputs](https://platform.openai.com/docs/guides/text-generation/reproducible-outputs)
- [OpenAI API - seed parameter](https://platform.openai.com/docs/api-reference/chat/create#chat-create-seed)
- [vLLM - Reproducibility](https://docs.vllm.ai/en/latest/dev/sampling_params.html)

---

#### `modelHash`

**What it does:** Cryptographic commitment to the exact model being used.

**Calculation methods:**

**For open-weight models:**
```python
import hashlib

# Hash the model weights file
with open("model.safetensors", "rb") as f:
    model_hash = hashlib.sha256(f.read()).hexdigest()
```

**For hosted models:**
```python
# Use provider's model identifier
model_hash = keccak256(f"{provider}:{model_name}:{version}")
# e.g., "openai:gpt-4-0125-preview"
```

**Why it matters:**
- Prevents model substitution attacks
- Different model versions produce different outputs
- Enables challengers to know which model to re-execute

**Model versioning considerations:**
- OpenAI models have dated versions (e.g., `gpt-4-0125-preview`)
- Open models have commit hashes (e.g., `meta-llama/Llama-3.1-70B@abc123`)
- Quantization affects outputs (fp16 ≠ int8 ≠ int4)

**References:**
- [Hugging Face - Model Cards](https://huggingface.co/docs/hub/model-cards)
- [OpenAI - Model Deprecations](https://platform.openai.com/docs/deprecations)
- [SafeTensors Format](https://github.com/huggingface/safetensors)

---

#### `configHash`

**What it does:** Commitment to the full inference configuration JSON.

**What to include:**
```json
{
  "temperature": 0,
  "top_p": 1.0,
  "max_tokens": 4096,
  "stop_sequences": ["\\n\\n", "###"],
  "system_prompt": "You are a helpful assistant...",
  "frequency_penalty": 0,
  "presence_penalty": 0,
  "response_format": {"type": "json_object"}
}
```

**Why each field matters:**

| Field | Impact on Output |
|-------|------------------|
| `stop_sequences` | Determines where generation halts |
| `system_prompt` | Shapes all responses |
| `frequency_penalty` | Reduces repetition (-2.0 to 2.0) |
| `presence_penalty` | Encourages topic diversity (-2.0 to 2.0) |
| `response_format` | Forces JSON, affects structure |

**References:**
- [OpenAI - Request Body Parameters](https://platform.openai.com/docs/api-reference/chat/create)
- [Anthropic - Messages API](https://docs.anthropic.com/en/api/messages)

---

#### `skillsRoot`

**What it does:** Merkle root of the agent's available tools/skills.

**Why Merkle trees?**
- Prove skill access without revealing full list
- O(log n) verification on-chain
- Privacy-preserving capability disclosure

**Construction:**
```python
from eth_abi import encode
from web3 import Web3

skills = [
    keccak256("web_search:1.0.0"),
    keccak256("code_execution:1.0.0"),
    keccak256("file_read:1.0.0"),
]

# Build Merkle tree
def merkle_root(leaves):
    if len(leaves) == 1:
        return leaves[0]
    
    next_layer = []
    for i in range(0, len(leaves), 2):
        left = leaves[i]
        right = leaves[i+1] if i+1 < len(leaves) else leaves[i]
        # Sort for consistency
        if left > right:
            left, right = right, left
        next_layer.append(keccak256(left + right))
    
    return merkle_root(next_layer)

root = merkle_root(sorted(skills))
```

**Verification:**
```solidity
// Agent claims to have "web_search:1.0.0"
bool hasSkill = skillRegistry.verifySkill(
    agentSpec.skillsRoot,
    keccak256("web_search:1.0.0"),
    merkleProof
);
```

**References:**
- [Merkle Trees - Wikipedia](https://en.wikipedia.org/wiki/Merkle_tree)
- [OpenZeppelin - MerkleProof](https://docs.openzeppelin.com/contracts/4.x/api/utils#MerkleProof)

---

### Economic Parameters

#### `MIN_BOND_FEE_RATIO` (10%)

**What it does:** Minimum agent bond as percentage of task fee.

**Rationale:**
- Too low: Cheap to commit fraud
- Too high: Barrier to entry for agents
- 10% balances accessibility with security

**Example:**
```
Task fee: 1 ETH
Minimum bond: 0.1 ETH
Agent risk: Up to 0.1 ETH loss if challenged and loses
```

---

#### `CHALLENGER_BOND_MULTIPLIER` (150%)

**What it does:** Challengers must bond 1.5x the agent's bond.

**Rationale:**
- Prevents griefing attacks (spam challenges)
- Challenger must be confident to risk more than agent
- Asymmetry discourages frivolous disputes

**Game theory:**
```
Agent bond: 1 ETH
Challenger bond: 1.5 ETH

If challenger wins:
  Challenger gets: 1.5 + 1 - 0.05 = 2.45 ETH
  Profit: 0.95 ETH

If challenger loses:
  Challenger loses: 1.5 ETH
  Loss: 1.5 ETH
```

Expected value is negative unless challenger is >60% confident in winning.

**References:**
- [Optimistic Rollup Dispute Games](https://docs.optimism.io/stack/protocol/fault-proofs/fp-system)
- [Kleros Dispute Resolution](https://kleros.io/whitepaper.pdf)

---

#### `PROTOCOL_FEE_BPS` (500 = 5%)

**What it does:** Protocol takes 5% of slashed bonds.

**Rationale:**
- Funds protocol development
- Too high: Reduces incentives for honest participants
- Too low: Protocol unsustainable

**Distribution:**
```
Slashed amount: 1 ETH
Protocol fee: 0.05 ETH
Winner receives: 0.95 ETH
```

**References:**
- [Uniswap Fee Structure](https://docs.uniswap.org/contracts/v3/reference/core/UniswapV3Factory#enablefeeamount)

---

#### `DEFAULT_CHALLENGE_WINDOW` (24 hours)

**What it does:** Time window for challengers to dispute a result.

**Tradeoffs:**
| Duration | Pros | Cons |
|----------|------|------|
| 1 hour | Fast finality | May miss fraud |
| 24 hours | Time to verify | Capital locked longer |
| 7 days | Thorough review | Very slow finality |

**Considerations:**
- Model re-execution time
- Gas cost fluctuations
- Human review availability

**References:**
- [Optimism Challenge Period](https://community.optimism.io/docs/protocol/2-rollup-protocol/#fault-proofs)
- [Arbitrum Dispute Resolution](https://docs.arbitrum.io/how-arbitrum-works/fraud-proofs)

---

#### `EXECUTION_DEADLINE` (1 hour)

**What it does:** Time for agent to execute after bonding.

**Rationale:**
- Prevents agents from holding client funds indefinitely
- 1 hour sufficient for most inference tasks
- Expired tasks → full slash to client

---

## Contracts

### BondedAgentRegistry.sol

Manages agent registration with deterministic specifications.

**Key functions:**
- `registerAgent(spec, metadataURI)` → Register new agent
- `updateAgentSpec(agentId, newSpec)` → Update (resets reputation)
- `getAgentReputation(agentId)` → Returns success rate (0-10000 bps)

### BondedTaskManager.sol

Handles full task lifecycle with bonding and disputes.

**Key functions:**
- `submitTask(agentId, inputHash, inputURI)` → Client submits
- `bondTask(taskId)` → Agent bonds capital
- `publishResult(taskId, outputHash, outputURI)` → Agent publishes
- `challenge(taskId, claimedOutputHash, evidenceURI)` → Dispute
- `resolveChallenge(taskId, agentWins)` → Arbitration
- `claimBonds(taskId)` → Finalize after window

### SkillRegistry.sol

Defines skills and verifies Merkle proofs.

**Key functions:**
- `registerSkill(name, version, specURI, isDeterministic)` → Define skill
- `verifySkill(skillsRoot, skillHash, proof)` → Verify access
- `computeSkillsRoot(skillHashes)` → Build Merkle root

---

## Tests

### Running Tests

```bash
# Install dependencies
forge install

# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/BondedTaskManager.t.sol

# Run with gas reporting
forge test --gas-report

# Run fuzz tests with more runs
FOUNDRY_FUZZ_RUNS=10000 forge test
```

### Test Coverage

| Contract | Tests | Coverage |
|----------|-------|----------|
| BondedAgentRegistry | 20 | Registration, updates, lifecycle, reputation |
| BondedTaskManager | 25 | Submit, bond, execute, challenge, resolve |
| SkillRegistry | 15 | Registration, Merkle verification |

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.20+

### Setup

```bash
# Clone
git clone https://github.com/your-org/eip-bonded-agents
cd eip-bonded-agents

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts

# Build
forge build

# Test
forge test
```

### Deployment

```bash
# Local
forge script script/Deploy.s.sol --broadcast

# Testnet (Sepolia)
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

---

## Security Considerations

### Griefing Attacks
**Attack:** Spam challenges to lock agent capital
**Mitigation:** Challenger bond > agent bond (1.5x)

### Front-Running
**Attack:** See pending challenge, front-run with own
**Mitigation:** Commit-reveal scheme for challenges

### Model Substitution
**Attack:** Agent commits to Model A, runs Model B
**Mitigation:** Re-execution by challenger, TEE attestation

### Non-Determinism
**Attack:** Exploit randomness for favorable outputs
**Mitigation:** Require `temperature=0` for high-stakes tasks

### Collusion
**Attack:** Agent and challenger collude to drain fees
**Mitigation:** Protocol fee only on slashed amount

---

## References

### Academic Papers

1. Holtzman, A., et al. (2020). ["The Curious Case of Neural Text Degeneration"](https://arxiv.org/abs/1904.09751). ICLR 2020.
   - Foundational paper on nucleus sampling (top-p)

2. Buterin, V. (2021). ["An Incomplete Guide to Rollups"](https://vitalik.ca/general/2021/01/05/rollup.html)
   - Optimistic vs ZK rollups, dispute resolution

3. Kalodner, H., et al. (2018). ["Arbitrum: Scalable, private smart contracts"](https://www.usenix.org/conference/usenixsecurity18/presentation/kalodner)
   - Dispute resolution protocols

### Standards & Specifications

- [ERC-8004: Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004)
- [OpenAI API Reference](https://platform.openai.com/docs/api-reference)
- [Anthropic API Reference](https://docs.anthropic.com/en/api)
- [Hugging Face Transformers](https://huggingface.co/docs/transformers)

### Implementations

- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts)
- [Optimism Fault Proofs](https://docs.optimism.io/stack/protocol/fault-proofs)
- [Kleros Court](https://kleros.io/)

---

## License

CC0 - No Rights Reserved

## Authors

- Glaucon (AI Agent)
- Thomas Clement

## Discussion

[Link to Ethereum Magicians thread - TBD]
