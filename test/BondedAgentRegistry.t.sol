// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BondedAgentRegistry} from "../contracts/BondedAgentRegistry.sol";

contract BondedAgentRegistryTest is Test {
    BondedAgentRegistry public registry;
    
    // Events (must match contract events for vm.expectEmit)
    event AgentRegistered(
        uint256 indexed agentId,
        address indexed owner,
        bytes32 indexed modelHash,
        bytes32 skillsRoot,
        string metadataURI
    );
    event AgentUpdated(uint256 indexed agentId, bytes32 newConfigHash, bytes32 newSkillsRoot);
    event AgentDeactivated(uint256 indexed agentId);
    event AgentReactivated(uint256 indexed agentId);
    event TaskRecorded(uint256 indexed agentId, uint256 indexed taskId, bool success);
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    
    // Sample agent specs
    BondedAgentRegistry.AgentSpec public llamaSpec;
    BondedAgentRegistry.AgentSpec public gptSpec;
    
    function setUp() public {
        registry = new BondedAgentRegistry();
        registry.transferOwnership(alice);
        
        // Llama 3.1 70B spec (deterministic)
        llamaSpec = BondedAgentRegistry.AgentSpec({
            modelHash: keccak256("meta-llama/Llama-3.1-70B-Instruct"),
            configHash: keccak256(abi.encodePacked(
                '{"temperature":0,"top_p":1,"max_tokens":4096,"do_sample":false}'
            )),
            skillsRoot: keccak256("web_search,code_execution,file_read"),
            maxTokens: 4096,
            temperature: 0,  // Deterministic
            topP: 100,       // 1.0
            randomSeed: 42
        });
        
        // GPT-4 spec (with some randomness)
        gptSpec = BondedAgentRegistry.AgentSpec({
            modelHash: keccak256("openai:gpt-4-0125-preview"),
            configHash: keccak256(abi.encodePacked(
                '{"temperature":0.7,"top_p":0.95,"max_tokens":4096}'
            )),
            skillsRoot: keccak256("web_search,dalle"),
            maxTokens: 4096,
            temperature: 70,  // 0.7
            topP: 95,         // 0.95
            randomSeed: 12345
        });
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_RegisterAgent_Success() public {
        vm.startPrank(alice);
        
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://QmAgent1");
        
        assertEq(agentId, 1);
        
        BondedAgentRegistry.Agent memory agent = registry.getAgent(agentId);
        assertEq(agent.owner, alice);
        assertEq(agent.spec.modelHash, llamaSpec.modelHash);
        assertEq(agent.spec.temperature, 0);
        assertEq(agent.metadataURI, "ipfs://QmAgent1");
        assertTrue(agent.active);
        assertEq(agent.totalTasks, 0);
        assertEq(agent.successfulTasks, 0);
        
        vm.stopPrank();
    }
    
    function test_RegisterAgent_EmitsEvent() public {
        vm.startPrank(alice);
        
        vm.expectEmit(true, true, true, true);
        emit AgentRegistered(
            1,
            alice,
            llamaSpec.modelHash,
            llamaSpec.skillsRoot,
            "ipfs://QmAgent1"
        );
        
        registry.registerAgent(llamaSpec, "ipfs://QmAgent1");
        
        vm.stopPrank();
    }
    
    function test_RegisterAgent_MultipleAgents() public {
        vm.startPrank(alice);
        uint256 id1 = registry.registerAgent(llamaSpec, "ipfs://1");
        vm.stopPrank();
        
        vm.startPrank(bob);
        uint256 id2 = registry.registerAgent(gptSpec, "ipfs://2");
        vm.stopPrank();
        
        assertEq(id1, 1);
        assertEq(id2, 2);
        
        assertEq(registry.getAgent(id1).owner, alice);
        assertEq(registry.getAgent(id2).owner, bob);
    }
    
    function test_RegisterAgent_InvalidModelHash_Reverts() public {
        BondedAgentRegistry.AgentSpec memory invalidSpec = llamaSpec;
        invalidSpec.modelHash = bytes32(0);
        
        vm.expectRevert(BondedAgentRegistry.InvalidModelHash.selector);
        registry.registerAgent(invalidSpec, "ipfs://test");
    }
    
    function test_RegisterAgent_InvalidSkillsRoot_Reverts() public {
        BondedAgentRegistry.AgentSpec memory invalidSpec = llamaSpec;
        invalidSpec.skillsRoot = bytes32(0);
        
        vm.expectRevert(BondedAgentRegistry.InvalidSkillsRoot.selector);
        registry.registerAgent(invalidSpec, "ipfs://test");
    }
    
    function test_RegisterAgent_InvalidTemperature_Reverts() public {
        BondedAgentRegistry.AgentSpec memory invalidSpec = llamaSpec;
        invalidSpec.temperature = 101; // > 100
        
        vm.expectRevert(BondedAgentRegistry.InvalidTemperature.selector);
        registry.registerAgent(invalidSpec, "ipfs://test");
    }
    
    function testFuzz_RegisterAgent_TemperatureBounds(uint8 temp) public {
        vm.assume(temp <= 100);
        
        BondedAgentRegistry.AgentSpec memory spec = llamaSpec;
        spec.temperature = temp;
        
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(spec, "ipfs://test");
        
        assertEq(registry.getAgentSpec(agentId).temperature, temp);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      UPDATE TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_UpdateAgentSpec_Success() public {
        vm.startPrank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        // Simulate some tasks
        // (In production, TaskManager would call recordTaskCompletion)
        
        // Update spec
        registry.updateAgentSpec(agentId, gptSpec);
        
        BondedAgentRegistry.Agent memory agent = registry.getAgent(agentId);
        assertEq(agent.spec.modelHash, gptSpec.modelHash);
        assertEq(agent.spec.temperature, 70);
        
        // Reputation should be reset
        assertEq(agent.totalTasks, 0);
        assertEq(agent.successfulTasks, 0);
        
        vm.stopPrank();
    }
    
    function test_UpdateAgentSpec_NotOwner_Reverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        vm.prank(bob);
        vm.expectRevert(BondedAgentRegistry.NotAgentOwner.selector);
        registry.updateAgentSpec(agentId, gptSpec);
    }
    
    function test_UpdateAgentSpec_NotFound_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(BondedAgentRegistry.AgentNotFound.selector);
        registry.updateAgentSpec(999, gptSpec);
    }
    
    function test_UpdateMetadataURI_Success() public {
        vm.startPrank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        registry.updateMetadataURI(agentId, "ipfs://2");
        
        assertEq(registry.getAgent(agentId).metadataURI, "ipfs://2");
        vm.stopPrank();
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_DeactivateAgent_Success() public {
        vm.startPrank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        assertTrue(registry.isAgentActive(agentId));
        
        registry.deactivateAgent(agentId);
        
        assertFalse(registry.isAgentActive(agentId));
        vm.stopPrank();
    }
    
    function test_ReactivateAgent_Success() public {
        vm.startPrank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        registry.deactivateAgent(agentId);
        assertFalse(registry.isAgentActive(agentId));
        
        registry.reactivateAgent(agentId);
        assertTrue(registry.isAgentActive(agentId));
        
        vm.stopPrank();
    }
    
    function test_TransferAgent_Success() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        assertEq(registry.getAgent(agentId).owner, alice);
        
        vm.prank(alice);
        registry.transferAgent(agentId, bob);
        
        assertEq(registry.getAgent(agentId).owner, bob);
    }
    
    function test_TransferAgent_NotOwner_Reverts() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        vm.prank(bob);
        vm.expectRevert(BondedAgentRegistry.NotAgentOwner.selector);
        registry.transferAgent(agentId, charlie);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      REPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_GetAgentReputation_NewAgent() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        // New agents default to 50% (5000 bps)
        assertEq(registry.getAgentReputation(agentId), 5000);
    }
    
    function test_GetAgentReputation_AfterTasks() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        // Simulate task completions
        registry.recordTaskCompletion(agentId, true);  // success
        registry.recordTaskCompletion(agentId, true);  // success
        registry.recordTaskCompletion(agentId, false); // failure
        registry.recordTaskCompletion(agentId, true);  // success
        
        // 3/4 = 75% = 7500 bps
        assertEq(registry.getAgentReputation(agentId), 7500);
    }
    
    function testFuzz_GetAgentReputation(
        uint256 successes,
        uint256 failures
    ) public {
        vm.assume(successes < 1000 && failures < 1000);
        vm.assume(successes + failures > 0);
        
        vm.prank(alice);
        uint256 agentId = registry.registerAgent(llamaSpec, "ipfs://1");
        
        for (uint256 i = 0; i < successes; i++) {
            registry.recordTaskCompletion(agentId, true);
        }
        for (uint256 i = 0; i < failures; i++) {
            registry.recordTaskCompletion(agentId, false);
        }
        
        uint256 expected = (successes * 10000) / (successes + failures);
        assertEq(registry.getAgentReputation(agentId), expected);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      INDEX TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_GetAgentsByOwner() public {
        vm.startPrank(alice);
        uint256 id1 = registry.registerAgent(llamaSpec, "ipfs://1");
        uint256 id2 = registry.registerAgent(gptSpec, "ipfs://2");
        vm.stopPrank();
        
        uint256[] memory aliceAgents = registry.getAgentsByOwner(alice);
        assertEq(aliceAgents.length, 2);
        assertEq(aliceAgents[0], id1);
        assertEq(aliceAgents[1], id2);
    }
    
    function test_GetAgentsByModel() public {
        vm.prank(alice);
        uint256 id1 = registry.registerAgent(llamaSpec, "ipfs://1");
        
        vm.prank(bob);
        uint256 id2 = registry.registerAgent(llamaSpec, "ipfs://2"); // Same model
        
        uint256[] memory llamaAgents = registry.getAgentsByModel(llamaSpec.modelHash);
        assertEq(llamaAgents.length, 2);
        assertEq(llamaAgents[0], id1);
        assertEq(llamaAgents[1], id2);
    }
}
