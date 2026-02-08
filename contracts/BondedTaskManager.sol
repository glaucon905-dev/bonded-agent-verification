// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BondedTaskManager
 * @notice Manages task lifecycle with bonding and challenge resolution
 * @dev Part of EIP-XXXX: Bonded Agent Verification
 */
contract BondedTaskManager is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ═══════════════════════════════════════════════════════════════
    //                           STRUCTS
    // ═══════════════════════════════════════════════════════════════
    
    enum TaskState {
        PENDING,            // Task submitted, awaiting agent bond
        COMMITTED,          // Agent bonded, ready for execution
        EXECUTED,           // Output published, challenge window open
        CHALLENGED,         // Active dispute
        RESOLVED_AGENT,     // Resolved in agent's favor
        RESOLVED_CHALLENGER,// Resolved in challenger's favor
        RESOLVED_NO_CHALLENGE, // Resolved without challenge (agent wins by default)
        EXPIRED             // Agent failed to execute in time
    }
    
    struct Task {
        // Identity
        uint256 agentId;
        address client;
        
        // Commitments
        bytes32 inputHash;          // keccak256(input)
        bytes32 outputHash;         // keccak256(output), set after execution
        string inputURI;            // Where to fetch actual input
        string outputURI;           // Where to fetch actual output
        
        // Economics
        uint256 fee;                // Payment to agent
        uint256 agentBond;          // Amount bonded by agent
        uint256 challengerBond;     // Amount bonded by challenger
        
        // Parties
        address agentOwner;         // Cached for payouts
        address challenger;         // Challenger address (if any)
        
        // Timing
        uint64 submittedAt;
        uint64 bondedAt;
        uint64 executedAt;
        uint64 challengeDeadline;
        
        // State
        TaskState state;
    }
    
    struct Challenge {
        bytes32 claimedOutputHash;  // Challenger's computed output
        string evidenceURI;         // Proof of re-execution
        uint64 challengedAt;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                           CONSTANTS
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Challenger must bond 1.5x agent bond
    uint256 public constant CHALLENGER_BOND_MULTIPLIER = 150;
    
    /// @notice Protocol fee on slashed bonds (5%)
    uint256 public constant PROTOCOL_FEE_BPS = 500;
    
    /// @notice Default challenge window (24 hours)
    uint64 public constant DEFAULT_CHALLENGE_WINDOW = 24 hours;
    
    /// @notice Time for agent to execute after bonding
    uint64 public constant EXECUTION_DEADLINE = 1 hours;
    
    /// @notice Minimum bond as percentage of fee (10%)
    uint256 public constant MIN_BOND_FEE_RATIO = 10;
    
    // ═══════════════════════════════════════════════════════════════
    //                           STORAGE
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Counter for task IDs
    uint256 public nextTaskId = 1;
    
    /// @notice Task ID => Task data
    mapping(uint256 => Task) public tasks;
    
    /// @notice Task ID => Challenge data
    mapping(uint256 => Challenge) public challenges;
    
    /// @notice Protocol treasury
    address public treasury;
    
    /// @notice Bond token (address(0) for ETH)
    IERC20 public bondToken;
    
    /// @notice Reference to agent registry
    address public agentRegistry;
    
    /// @notice Custom challenge windows per agent
    mapping(uint256 => uint64) public agentChallengeWindows;
    
    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════
    
    event TaskSubmitted(
        uint256 indexed taskId,
        uint256 indexed agentId,
        address indexed client,
        bytes32 inputHash,
        uint256 fee
    );
    
    event TaskBonded(
        uint256 indexed taskId,
        address indexed agentOwner,
        uint256 bondAmount
    );
    
    event TaskExecuted(
        uint256 indexed taskId,
        bytes32 outputHash,
        string outputURI,
        uint64 challengeDeadline
    );
    
    event TaskChallenged(
        uint256 indexed taskId,
        address indexed challenger,
        bytes32 claimedOutputHash,
        uint256 challengerBond
    );
    
    event TaskResolved(
        uint256 indexed taskId,
        TaskState resolution,
        address winner,
        uint256 payout
    );
    
    event TaskExpired(uint256 indexed taskId);
    
    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error TaskNotFound();
    error InvalidState();
    error InsufficientBond();
    error InsufficientChallengerBond();
    error NotAgentOwner();
    error ChallengeWindowClosed();
    error ChallengeWindowOpen();
    error AlreadyChallenged();
    error CannotChallengeSelf();
    error ExecutionDeadlinePassed();
    error InvalidInputHash();
    
    // ═══════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════
    
    constructor(address _treasury, address _bondToken, address _agentRegistry) {
        treasury = _treasury;
        bondToken = IERC20(_bondToken);
        agentRegistry = _agentRegistry;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      TASK SUBMISSION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Submit a task for an agent to execute
     * @param agentId The agent to execute the task
     * @param inputHash keccak256 of the input data
     * @param inputURI Where to fetch the actual input
     * @return taskId The unique task identifier
     */
    function submitTask(
        uint256 agentId,
        bytes32 inputHash,
        string calldata inputURI
    ) external payable returns (uint256 taskId) {
        if (inputHash == bytes32(0)) revert InvalidInputHash();
        
        taskId = nextTaskId++;
        
        tasks[taskId] = Task({
            agentId: agentId,
            client: msg.sender,
            inputHash: inputHash,
            outputHash: bytes32(0),
            inputURI: inputURI,
            outputURI: "",
            fee: msg.value,
            agentBond: 0,
            challengerBond: 0,
            agentOwner: address(0),
            challenger: address(0),
            submittedAt: uint64(block.timestamp),
            bondedAt: 0,
            executedAt: 0,
            challengeDeadline: 0,
            state: TaskState.PENDING
        });
        
        emit TaskSubmitted(taskId, agentId, msg.sender, inputHash, msg.value);
    }
    
    /**
     * @notice Agent bonds capital and commits to execute
     * @param taskId The task to bond
     */
    function bondTask(uint256 taskId) external payable nonReentrant {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.PENDING) revert InvalidState();
        
        // Calculate minimum bond
        uint256 minBond = (task.fee * MIN_BOND_FEE_RATIO) / 100;
        if (msg.value < minBond) revert InsufficientBond();
        
        task.agentBond = msg.value;
        task.agentOwner = msg.sender;
        task.bondedAt = uint64(block.timestamp);
        task.state = TaskState.COMMITTED;
        
        emit TaskBonded(taskId, msg.sender, msg.value);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      EXECUTION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Agent publishes execution result
     * @param taskId The task that was executed
     * @param outputHash keccak256 of the output
     * @param outputURI Where to fetch the actual output
     */
    function publishResult(
        uint256 taskId,
        bytes32 outputHash,
        string calldata outputURI
    ) external {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.COMMITTED) revert InvalidState();
        if (task.agentOwner != msg.sender) revert NotAgentOwner();
        
        // Check execution deadline
        if (block.timestamp > task.bondedAt + EXECUTION_DEADLINE) {
            revert ExecutionDeadlinePassed();
        }
        
        // Determine challenge window
        uint64 challengeWindow = agentChallengeWindows[task.agentId];
        if (challengeWindow == 0) {
            challengeWindow = DEFAULT_CHALLENGE_WINDOW;
        }
        
        task.outputHash = outputHash;
        task.outputURI = outputURI;
        task.executedAt = uint64(block.timestamp);
        task.challengeDeadline = uint64(block.timestamp) + challengeWindow;
        task.state = TaskState.EXECUTED;
        
        emit TaskExecuted(taskId, outputHash, outputURI, task.challengeDeadline);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      CHALLENGE
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Challenge a task result
     * @param taskId The task to challenge
     * @param claimedOutputHash The challenger's computed correct output
     * @param evidenceURI Link to re-execution proof
     */
    function challenge(
        uint256 taskId,
        bytes32 claimedOutputHash,
        string calldata evidenceURI
    ) external payable nonReentrant {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.EXECUTED) revert InvalidState();
        if (block.timestamp > task.challengeDeadline) revert ChallengeWindowClosed();
        if (task.challenger != address(0)) revert AlreadyChallenged();
        if (msg.sender == task.agentOwner) revert CannotChallengeSelf();
        
        // Calculate required challenger bond (1.5x agent bond)
        uint256 requiredBond = (task.agentBond * CHALLENGER_BOND_MULTIPLIER) / 100;
        if (msg.value < requiredBond) revert InsufficientChallengerBond();
        
        task.challenger = msg.sender;
        task.challengerBond = msg.value;
        task.state = TaskState.CHALLENGED;
        
        challenges[taskId] = Challenge({
            claimedOutputHash: claimedOutputHash,
            evidenceURI: evidenceURI,
            challengedAt: uint64(block.timestamp)
        });
        
        emit TaskChallenged(taskId, msg.sender, claimedOutputHash, msg.value);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      RESOLUTION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Resolve a challenged task
     * @dev In production, this would integrate with an arbitration system
     * @param taskId The task to resolve
     * @param agentWins True if agent's output was correct
     */
    function resolveChallenge(
        uint256 taskId,
        bool agentWins
    ) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.CHALLENGED) revert InvalidState();
        
        // TODO: In production, verify caller is authorized resolver
        // For now, anyone can resolve (demonstration only)
        
        uint256 protocolFee;
        uint256 winnerPayout;
        address winner;
        
        if (agentWins) {
            task.state = TaskState.RESOLVED_AGENT;
            winner = task.agentOwner;
            
            // Agent gets: own bond + challenger bond - protocol fee
            protocolFee = (task.challengerBond * PROTOCOL_FEE_BPS) / 10000;
            winnerPayout = task.agentBond + task.challengerBond - protocolFee + task.fee;
        } else {
            task.state = TaskState.RESOLVED_CHALLENGER;
            winner = task.challenger;
            
            // Challenger gets: own bond + agent bond - protocol fee
            protocolFee = (task.agentBond * PROTOCOL_FEE_BPS) / 10000;
            winnerPayout = task.challengerBond + task.agentBond - protocolFee;
            
            // Client gets fee refunded
            payable(task.client).transfer(task.fee);
        }
        
        // Pay winner and protocol
        payable(winner).transfer(winnerPayout);
        payable(treasury).transfer(protocolFee);
        
        emit TaskResolved(taskId, task.state, winner, winnerPayout);
    }
    
    /**
     * @notice Claim bonds after challenge window closes (no challenge case)
     * @param taskId The task to finalize
     */
    function claimBonds(uint256 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.EXECUTED) revert InvalidState();
        if (block.timestamp <= task.challengeDeadline) revert ChallengeWindowOpen();
        
        task.state = TaskState.RESOLVED_NO_CHALLENGE;
        
        // Agent gets: bond back + fee
        uint256 payout = task.agentBond + task.fee;
        payable(task.agentOwner).transfer(payout);
        
        emit TaskResolved(taskId, TaskState.RESOLVED_NO_CHALLENGE, task.agentOwner, payout);
    }
    
    /**
     * @notice Mark task as expired if agent didn't execute in time
     * @param taskId The expired task
     */
    function expireTask(uint256 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.client == address(0)) revert TaskNotFound();
        if (task.state != TaskState.COMMITTED) revert InvalidState();
        if (block.timestamp <= task.bondedAt + EXECUTION_DEADLINE) {
            revert InvalidState(); // Not yet expired
        }
        
        task.state = TaskState.EXPIRED;
        
        // Slash agent bond, return to client with fee
        payable(task.client).transfer(task.fee + task.agentBond);
        
        emit TaskExpired(taskId);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    
    function getTask(uint256 taskId) external view returns (Task memory) {
        return tasks[taskId];
    }
    
    function getChallenge(uint256 taskId) external view returns (Challenge memory) {
        return challenges[taskId];
    }
    
    function getRequiredChallengerBond(uint256 taskId) external view returns (uint256) {
        return (tasks[taskId].agentBond * CHALLENGER_BOND_MULTIPLIER) / 100;
    }
    
    function isChallengeWindowOpen(uint256 taskId) external view returns (bool) {
        Task storage task = tasks[taskId];
        return task.state == TaskState.EXECUTED && 
               block.timestamp <= task.challengeDeadline;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      ADMIN
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Set custom challenge window for an agent
     * @param agentId The agent ID
     * @param window Challenge window duration in seconds
     */
    function setAgentChallengeWindow(uint256 agentId, uint64 window) external {
        // TODO: Access control - only agent owner or admin
        agentChallengeWindows[agentId] = window;
    }
}
