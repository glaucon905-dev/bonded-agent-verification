// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BondedTaskManager} from "../contracts/BondedTaskManager.sol";
import {BondedAgentRegistry} from "../contracts/BondedAgentRegistry.sol";

contract BondedTaskManagerTest is Test {
    BondedTaskManager public taskManager;
    BondedAgentRegistry public registry;
    
    // Events (must match contract events for vm.expectEmit)
    event TaskSubmitted(
        uint256 indexed taskId,
        uint256 indexed agentId,
        address indexed client,
        bytes32 inputHash,
        uint256 reward
    );
    
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");     // Agent owner
    address public bob = makeAddr("bob");         // Client
    address public charlie = makeAddr("charlie"); // Challenger
    
    uint256 public agentId;
    
    // Sample hashes
    bytes32 public inputHash = keccak256("What is the price of ETH?");
    bytes32 public outputHash = keccak256("ETH is $3,200");
    bytes32 public wrongOutputHash = keccak256("ETH is $1,000");
    
    function setUp() public {
        registry = new BondedAgentRegistry();
        taskManager = new BondedTaskManager(
            treasury,
            address(0), // ETH for bonds
            address(registry)
        );
        
        // Register an agent
        BondedAgentRegistry.AgentSpec memory spec = BondedAgentRegistry.AgentSpec({
            modelHash: keccak256("meta-llama/Llama-3.1-70B"),
            configHash: keccak256("temp=0"),
            skillsRoot: keccak256("web_search"),
            maxTokens: 4096,
            temperature: 0,
            topP: 100,
            randomSeed: 42
        });
        
        vm.prank(alice);
        agentId = registry.registerAgent(spec, "ipfs://agent");
        
        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      TASK SUBMISSION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_SubmitTask_Success() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId,
            inputHash,
            "ipfs://input"
        );
        
        assertEq(taskId, 1);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.agentId, agentId);
        assertEq(task.client, bob);
        assertEq(task.inputHash, inputHash);
        assertEq(task.fee, 1 ether);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.PENDING));
    }
    
    function test_SubmitTask_EmitsEvent() public {
        vm.prank(bob);
        
        vm.expectEmit(true, true, true, true);
        emit TaskSubmitted(1, agentId, bob, inputHash, 1 ether);
        
        taskManager.submitTask{value: 1 ether}(agentId, inputHash, "ipfs://input");
    }
    
    function test_SubmitTask_InvalidInputHash_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(BondedTaskManager.InvalidInputHash.selector);
        taskManager.submitTask{value: 1 ether}(agentId, bytes32(0), "ipfs://input");
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      BONDING TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_BondTask_Success() public {
        // Submit task
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        // Calculate min bond (10% of fee)
        uint256 minBond = 0.1 ether;
        
        // Agent bonds
        vm.prank(alice);
        taskManager.bondTask{value: minBond}(taskId);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.agentBond, minBond);
        assertEq(task.agentOwner, alice);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.COMMITTED));
    }
    
    function test_BondTask_InsufficientBond_Reverts() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        // Try to bond less than 10%
        vm.prank(alice);
        vm.expectRevert(BondedTaskManager.InsufficientBond.selector);
        taskManager.bondTask{value: 0.05 ether}(taskId);
    }
    
    function test_BondTask_WrongState_Reverts() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        // Bond once
        vm.prank(alice);
        taskManager.bondTask{value: 0.1 ether}(taskId);
        
        // Try to bond again
        vm.prank(alice);
        vm.expectRevert(BondedTaskManager.InvalidState.selector);
        taskManager.bondTask{value: 0.1 ether}(taskId);
    }
    
    function testFuzz_BondTask_MinimumBondCalculation(uint256 fee) public {
        vm.assume(fee > 0.1 ether && fee < 10 ether);
        
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: fee}(
            agentId, inputHash, "ipfs://input"
        );
        
        uint256 minBond = fee / 10; // 10%
        
        // Should fail with less than min
        vm.prank(alice);
        vm.expectRevert(BondedTaskManager.InsufficientBond.selector);
        taskManager.bondTask{value: minBond - 1}(taskId);
        
        // Should succeed with exactly min
        vm.prank(alice);
        taskManager.bondTask{value: minBond}(taskId);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      EXECUTION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_PublishResult_Success() public {
        // Setup: submit and bond
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 0.1 ether}(taskId);
        
        // Publish result
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.outputHash, outputHash);
        assertEq(task.outputURI, "ipfs://output");
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.EXECUTED));
        assertTrue(task.challengeDeadline > block.timestamp);
    }
    
    function test_PublishResult_NotAgentOwner_Reverts() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 0.1 ether}(taskId);
        
        // Bob tries to publish (not agent owner)
        vm.prank(bob);
        vm.expectRevert(BondedTaskManager.NotAgentOwner.selector);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
    }
    
    function test_PublishResult_AfterDeadline_Reverts() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 0.1 ether}(taskId);
        
        // Warp past execution deadline (1 hour)
        vm.warp(block.timestamp + 2 hours);
        
        vm.prank(alice);
        vm.expectRevert(BondedTaskManager.ExecutionDeadlinePassed.selector);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      CHALLENGE TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_Challenge_Success() public {
        // Setup: full flow to executed state
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Challenge requires 1.5x agent bond = 1.5 ether
        uint256 challengerBond = 1.5 ether;
        
        vm.prank(charlie);
        taskManager.challenge{value: challengerBond}(
            taskId,
            wrongOutputHash,
            "ipfs://evidence"
        );
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(task.challenger, charlie);
        assertEq(task.challengerBond, challengerBond);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.CHALLENGED));
        
        BondedTaskManager.Challenge memory challenge = taskManager.getChallenge(taskId);
        assertEq(challenge.claimedOutputHash, wrongOutputHash);
    }
    
    function test_Challenge_InsufficientBond_Reverts() public {
        // Setup
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Try to challenge with less than 1.5x
        vm.prank(charlie);
        vm.expectRevert(BondedTaskManager.InsufficientChallengerBond.selector);
        taskManager.challenge{value: 1 ether}(taskId, wrongOutputHash, "ipfs://evidence");
    }
    
    function test_Challenge_AfterDeadline_Reverts() public {
        // Setup
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Warp past challenge deadline (24 hours)
        vm.warp(block.timestamp + 25 hours);
        
        vm.prank(charlie);
        vm.expectRevert(BondedTaskManager.ChallengeWindowClosed.selector);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence");
    }
    
    function test_Challenge_SelfChallenge_Reverts() public {
        // Setup
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Agent owner tries to self-challenge (to drain protocol?)
        vm.prank(alice);
        vm.expectRevert(BondedTaskManager.CannotChallengeSelf.selector);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence");
    }
    
    function test_Challenge_AlreadyChallenged_Reverts() public {
        // Setup
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // First challenge
        vm.prank(charlie);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence");
        
        // Second challenge attempt
        address dave = makeAddr("dave");
        vm.deal(dave, 10 ether);
        
        vm.prank(dave);
        vm.expectRevert(BondedTaskManager.InvalidState.selector);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence2");
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      RESOLUTION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_ResolveChallenge_AgentWins() public {
        // Setup challenged task
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        vm.prank(charlie);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence");
        
        uint256 aliceBalanceBefore = alice.balance;
        uint256 treasuryBalanceBefore = treasury.balance;
        
        // Resolve in agent's favor
        taskManager.resolveChallenge(taskId, true);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.RESOLVED_AGENT));
        
        // Agent gets: 1 ether (bond) + 1.5 ether (challenger) - 5% fee + 1 ether (fee)
        // Protocol fee: 1.5 * 0.05 = 0.075 ether
        uint256 expectedAgentPayout = 1 ether + 1.5 ether - 0.075 ether + 1 ether;
        assertEq(alice.balance - aliceBalanceBefore, expectedAgentPayout);
        assertEq(treasury.balance - treasuryBalanceBefore, 0.075 ether);
    }
    
    function test_ResolveChallenge_ChallengerWins() public {
        // Setup challenged task
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        vm.prank(charlie);
        taskManager.challenge{value: 1.5 ether}(taskId, wrongOutputHash, "ipfs://evidence");
        
        uint256 charlieBalanceBefore = charlie.balance;
        uint256 bobBalanceBefore = bob.balance;
        uint256 treasuryBalanceBefore = treasury.balance;
        
        // Resolve in challenger's favor
        taskManager.resolveChallenge(taskId, false);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.RESOLVED_CHALLENGER));
        
        // Challenger gets: 1.5 ether (own bond) + 1 ether (agent) - 5% fee
        // Protocol fee: 1 * 0.05 = 0.05 ether
        uint256 expectedChallengerPayout = 1.5 ether + 1 ether - 0.05 ether;
        assertEq(charlie.balance - charlieBalanceBefore, expectedChallengerPayout);
        
        // Client gets fee refunded
        assertEq(bob.balance - bobBalanceBefore, 1 ether);
        
        // Treasury gets fee
        assertEq(treasury.balance - treasuryBalanceBefore, 0.05 ether);
    }
    
    function test_ClaimBonds_NoChallengeSuccess() public {
        // Setup: complete execution
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Warp past challenge deadline
        vm.warp(block.timestamp + 25 hours);
        
        uint256 aliceBalanceBefore = alice.balance;
        
        // Claim
        taskManager.claimBonds(taskId);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.RESOLVED_NO_CHALLENGE));
        
        // Agent gets: bond + fee
        assertEq(alice.balance - aliceBalanceBefore, 2 ether);
    }
    
    function test_ClaimBonds_DuringChallengeWindow_Reverts() public {
        // Setup
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Try to claim before window closes
        vm.expectRevert(BondedTaskManager.ChallengeWindowOpen.selector);
        taskManager.claimBonds(taskId);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      EXPIRATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_ExpireTask_Success() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        // Don't publish result, warp past execution deadline
        vm.warp(block.timestamp + 2 hours);
        
        uint256 bobBalanceBefore = bob.balance;
        
        taskManager.expireTask(taskId);
        
        BondedTaskManager.Task memory task = taskManager.getTask(taskId);
        assertEq(uint8(task.state), uint8(BondedTaskManager.TaskState.EXPIRED));
        
        // Client gets: fee + slashed agent bond
        assertEq(bob.balance - bobBalanceBefore, 2 ether);
    }
    
    function test_ExpireTask_BeforeDeadline_Reverts() public {
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: 1 ether}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: 1 ether}(taskId);
        
        // Try to expire before deadline
        vm.expectRevert(BondedTaskManager.InvalidState.selector);
        taskManager.expireTask(taskId);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function testFuzz_ChallengerBondMultiplier(uint256 agentBond) public {
        vm.assume(agentBond > 0.1 ether && agentBond < 10 ether);
        
        uint256 expectedChallengerBond = (agentBond * 150) / 100;
        
        // Setup with specific agent bond
        vm.prank(bob);
        uint256 taskId = taskManager.submitTask{value: agentBond}(
            agentId, inputHash, "ipfs://input"
        );
        
        vm.prank(alice);
        taskManager.bondTask{value: agentBond}(taskId);
        
        vm.prank(alice);
        taskManager.publishResult(taskId, outputHash, "ipfs://output");
        
        // Verify required challenger bond
        assertEq(taskManager.getRequiredChallengerBond(taskId), expectedChallengerBond);
    }
    
    function testFuzz_ProtocolFeeCalculation(uint256 slashedAmount) public {
        vm.assume(slashedAmount > 0.1 ether && slashedAmount < 100 ether);
        
        // 5% of slashed amount
        uint256 expectedFee = (slashedAmount * 500) / 10000;
        
        // This is tested implicitly in resolve tests, but we verify the math
        assertEq(expectedFee, slashedAmount * 5 / 100);
    }
}
