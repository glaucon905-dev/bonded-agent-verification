// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BondedAgentRegistry
 * @notice Registry for agents with deterministic model specifications
 * @dev Part of EIP-XXXX: Bonded Agent Verification
 */
contract BondedAgentRegistry is Ownable, ReentrancyGuard {
    
    constructor() Ownable(msg.sender) {}
    
    // ═══════════════════════════════════════════════════════════════
    //                           STRUCTS
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Deterministic specification of an agent's model and capabilities
    struct AgentSpec {
        bytes32 modelHash;        // keccak256(model_weights) or provider identifier
        bytes32 configHash;       // keccak256(inference_config_json)
        bytes32 skillsRoot;       // Merkle root of available skills
        uint64 maxTokens;         // Maximum output tokens
        uint8 temperature;        // 0-100 (0 = deterministic, 100 = max randomness)
        uint8 topP;               // 0-100 (nucleus sampling parameter)
        uint64 randomSeed;        // For reproducibility
    }
    
    /// @notice Full agent record
    struct Agent {
        address owner;
        AgentSpec spec;
        string metadataURI;       // IPFS/HTTPS link to full metadata
        uint256 totalTasks;       // Number of tasks executed
        uint256 successfulTasks;  // Tasks without successful challenges
        uint64 registeredAt;
        uint64 lastUpdated;
        bool active;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                           STORAGE
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Counter for agent IDs
    uint256 public nextAgentId = 1;
    
    /// @notice Agent ID => Agent data
    mapping(uint256 => Agent) public agents;
    
    /// @notice Owner address => list of agent IDs
    mapping(address => uint256[]) public ownerAgents;
    
    /// @notice Model hash => list of agent IDs using that model
    mapping(bytes32 => uint256[]) public modelAgents;
    
    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════
    
    event AgentRegistered(
        uint256 indexed agentId,
        address indexed owner,
        bytes32 indexed modelHash,
        bytes32 skillsRoot,
        string metadataURI
    );
    
    event AgentSpecUpdated(
        uint256 indexed agentId,
        bytes32 oldModelHash,
        bytes32 newModelHash,
        bytes32 newSkillsRoot
    );
    
    event AgentMetadataUpdated(
        uint256 indexed agentId,
        string newMetadataURI
    );
    
    event AgentDeactivated(uint256 indexed agentId);
    event AgentReactivated(uint256 indexed agentId);
    event AgentTransferred(uint256 indexed agentId, address indexed from, address indexed to);
    
    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error AgentNotFound();
    error NotAgentOwner();
    error AgentNotActive();
    error InvalidModelHash();
    error InvalidSkillsRoot();
    error InvalidTemperature();
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Register a new agent with its specification
     * @param spec The agent's deterministic model specification
     * @param metadataURI IPFS/HTTPS link to full agent metadata JSON
     * @return agentId The unique identifier for the registered agent
     */
    function registerAgent(
        AgentSpec calldata spec,
        string calldata metadataURI
    ) external returns (uint256 agentId) {
        _validateSpec(spec);
        
        agentId = nextAgentId++;
        
        agents[agentId] = Agent({
            owner: msg.sender,
            spec: spec,
            metadataURI: metadataURI,
            totalTasks: 0,
            successfulTasks: 0,
            registeredAt: uint64(block.timestamp),
            lastUpdated: uint64(block.timestamp),
            active: true
        });
        
        ownerAgents[msg.sender].push(agentId);
        modelAgents[spec.modelHash].push(agentId);
        
        emit AgentRegistered(
            agentId,
            msg.sender,
            spec.modelHash,
            spec.skillsRoot,
            metadataURI
        );
    }
    
    /**
     * @notice Update an agent's specification
     * @dev Resets reputation metrics as the agent is effectively different
     * @param agentId The agent to update
     * @param newSpec The new specification
     */
    function updateAgentSpec(
        uint256 agentId,
        AgentSpec calldata newSpec
    ) external {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert NotAgentOwner();
        
        _validateSpec(newSpec);
        
        bytes32 oldModelHash = agent.spec.modelHash;
        
        // Reset reputation on spec change
        agent.totalTasks = 0;
        agent.successfulTasks = 0;
        agent.spec = newSpec;
        agent.lastUpdated = uint64(block.timestamp);
        
        // Update model index if changed
        if (oldModelHash != newSpec.modelHash) {
            modelAgents[newSpec.modelHash].push(agentId);
            // Note: doesn't remove from old index for gas efficiency
            // Off-chain indexers should filter by current spec
        }
        
        emit AgentSpecUpdated(agentId, oldModelHash, newSpec.modelHash, newSpec.skillsRoot);
    }
    
    /**
     * @notice Update agent metadata URI without changing spec
     * @param agentId The agent to update
     * @param newMetadataURI New IPFS/HTTPS link
     */
    function updateMetadataURI(
        uint256 agentId,
        string calldata newMetadataURI
    ) external {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert NotAgentOwner();
        
        agent.metadataURI = newMetadataURI;
        agent.lastUpdated = uint64(block.timestamp);
        
        emit AgentMetadataUpdated(agentId, newMetadataURI);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      LIFECYCLE
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Deactivate an agent (stops accepting new tasks)
     */
    function deactivateAgent(uint256 agentId) external {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert NotAgentOwner();
        
        agent.active = false;
        emit AgentDeactivated(agentId);
    }
    
    /**
     * @notice Reactivate a deactivated agent
     */
    function reactivateAgent(uint256 agentId) external {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert NotAgentOwner();
        
        agent.active = true;
        emit AgentReactivated(agentId);
    }
    
    /**
     * @notice Transfer agent ownership
     */
    function transferAgent(uint256 agentId, address newOwner) external {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert NotAgentOwner();
        
        address oldOwner = agent.owner;
        agent.owner = newOwner;
        ownerAgents[newOwner].push(agentId);
        
        emit AgentTransferred(agentId, oldOwner, newOwner);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      TASK TRACKING (called by TaskManager)
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Record a completed task
     * @dev Only callable by authorized TaskManager contract
     */
    function recordTaskCompletion(
        uint256 agentId,
        bool wasSuccessful
    ) external {
        // TODO: Add access control for TaskManager
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        
        agent.totalTasks++;
        if (wasSuccessful) {
            agent.successfulTasks++;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Get full agent data
     */
    function getAgent(uint256 agentId) external view returns (Agent memory) {
        if (agents[agentId].owner == address(0)) revert AgentNotFound();
        return agents[agentId];
    }
    
    /**
     * @notice Get agent specification only
     */
    function getAgentSpec(uint256 agentId) external view returns (AgentSpec memory) {
        if (agents[agentId].owner == address(0)) revert AgentNotFound();
        return agents[agentId].spec;
    }
    
    /**
     * @notice Get agent reputation as basis points (0-10000)
     */
    function getAgentReputation(uint256 agentId) external view returns (uint256) {
        Agent storage agent = agents[agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.totalTasks == 0) return 5000; // Default 50% for new agents
        
        return (agent.successfulTasks * 10000) / agent.totalTasks;
    }
    
    /**
     * @notice Check if agent is active and ready for tasks
     */
    function isAgentActive(uint256 agentId) external view returns (bool) {
        return agents[agentId].active;
    }
    
    /**
     * @notice Get all agents owned by an address
     */
    function getAgentsByOwner(address owner) external view returns (uint256[] memory) {
        return ownerAgents[owner];
    }
    
    /**
     * @notice Get all agents using a specific model
     */
    function getAgentsByModel(bytes32 modelHash) external view returns (uint256[] memory) {
        return modelAgents[modelHash];
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      INTERNAL
    // ═══════════════════════════════════════════════════════════════
    
    function _validateSpec(AgentSpec calldata spec) internal pure {
        if (spec.modelHash == bytes32(0)) revert InvalidModelHash();
        if (spec.skillsRoot == bytes32(0)) revert InvalidSkillsRoot();
        if (spec.temperature > 100) revert InvalidTemperature();
    }
}
