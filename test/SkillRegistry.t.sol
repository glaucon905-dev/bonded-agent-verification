// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SkillRegistry} from "../contracts/SkillRegistry.sol";

contract SkillRegistryTest is Test {
    SkillRegistry public registry;
    
    // Events (must match contract events for vm.expectEmit)
    event SkillRegistered(
        bytes32 indexed skillHash,
        string indexed name,
        string version,
        string specURI,
        bool isDeterministic
    );
    
    address public alice = makeAddr("alice");
    
    function setUp() public {
        registry = new SkillRegistry();
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_RegisterSkill_Success() public {
        vm.prank(alice);
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "ipfs://QmWebSearch",
            false // not deterministic
        );
        
        bytes32 expectedHash = keccak256(abi.encodePacked("web_search", "1.0.0"));
        assertEq(skillHash, expectedHash);
        
        SkillRegistry.Skill memory skill = registry.getSkill(skillHash);
        assertEq(skill.name, "web_search");
        assertEq(skill.version, "1.0.0");
        assertEq(skill.specURI, "ipfs://QmWebSearch");
        assertFalse(skill.isDeterministic);
        assertEq(skill.registrant, alice);
    }
    
    function test_RegisterSkill_Deterministic() public {
        bytes32 skillHash = registry.registerSkill(
            "math_eval",
            "1.0.0",
            "ipfs://QmMath",
            true // deterministic
        );
        
        assertTrue(registry.isSkillDeterministic(skillHash));
    }
    
    function test_RegisterSkill_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SkillRegistered(
            keccak256(abi.encodePacked("web_search", "1.0.0")),
            "web_search",
            "1.0.0",
            "ipfs://QmWebSearch",
            false
        );
        
        registry.registerSkill("web_search", "1.0.0", "ipfs://QmWebSearch", false);
    }
    
    function test_RegisterSkill_Duplicate_Reverts() public {
        registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        
        vm.expectRevert(SkillRegistry.SkillAlreadyRegistered.selector);
        registry.registerSkill("web_search", "1.0.0", "ipfs://2", true);
    }
    
    function test_RegisterSkill_DifferentVersions() public {
        bytes32 hash1 = registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        bytes32 hash2 = registry.registerSkill("web_search", "2.0.0", "ipfs://2", false);
        
        assertTrue(hash1 != hash2);
        
        assertEq(registry.getSkill(hash1).version, "1.0.0");
        assertEq(registry.getSkill(hash2).version, "2.0.0");
    }
    
    function test_RegisterSkillsBatch_Success() public {
        string[] memory names = new string[](3);
        names[0] = "web_search";
        names[1] = "code_execution";
        names[2] = "file_read";
        
        string[] memory versions = new string[](3);
        versions[0] = "1.0.0";
        versions[1] = "1.0.0";
        versions[2] = "1.0.0";
        
        string[] memory uris = new string[](3);
        uris[0] = "ipfs://1";
        uris[1] = "ipfs://2";
        uris[2] = "ipfs://3";
        
        bool[] memory deterministic = new bool[](3);
        deterministic[0] = false;
        deterministic[1] = true;
        deterministic[2] = true;
        
        bytes32[] memory hashes = registry.registerSkillsBatch(
            names, versions, uris, deterministic
        );
        
        assertEq(hashes.length, 3);
        assertEq(registry.getAllSkillsCount(), 3);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      MERKLE VERIFICATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_ComputeSkillsRoot_SingleSkill() public {
        bytes32 skillHash = keccak256(abi.encodePacked("web_search", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](1);
        skills[0] = skillHash;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Single skill root is just the skill hash
        assertEq(root, skillHash);
    }
    
    function test_ComputeSkillsRoot_TwoSkills() public {
        bytes32 skill1 = keccak256(abi.encodePacked("web_search", "1.0.0"));
        bytes32 skill2 = keccak256(abi.encodePacked("code_execution", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](2);
        skills[0] = skill1;
        skills[1] = skill2;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Root should be hash of sorted pair
        bytes32 expectedRoot;
        if (skill1 < skill2) {
            expectedRoot = keccak256(abi.encodePacked(skill1, skill2));
        } else {
            expectedRoot = keccak256(abi.encodePacked(skill2, skill1));
        }
        
        assertEq(root, expectedRoot);
    }
    
    function test_VerifySkill_TwoSkillTree() public {
        bytes32 skill1 = keccak256(abi.encodePacked("web_search", "1.0.0"));
        bytes32 skill2 = keccak256(abi.encodePacked("code_execution", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](2);
        skills[0] = skill1;
        skills[1] = skill2;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Build proof for skill1
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = skill2;
        
        // Verify skill1 is in tree
        bool isValid = registry.verifySkill(root, skill1, proof);
        assertTrue(isValid);
        
        // Verify skill2 with swapped proof
        proof[0] = skill1;
        isValid = registry.verifySkill(root, skill2, proof);
        assertTrue(isValid);
    }
    
    function test_VerifySkill_InvalidProof() public {
        bytes32 skill1 = keccak256(abi.encodePacked("web_search", "1.0.0"));
        bytes32 skill2 = keccak256(abi.encodePacked("code_execution", "1.0.0"));
        bytes32 skill3 = keccak256(abi.encodePacked("file_read", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](2);
        skills[0] = skill1;
        skills[1] = skill2;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Try to verify skill3 which is NOT in tree
        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = skill2;
        
        bool isValid = registry.verifySkill(root, skill3, fakeProof);
        assertFalse(isValid);
    }
    
    function test_VerifySkills_Batch() public {
        bytes32 skill1 = keccak256(abi.encodePacked("web_search", "1.0.0"));
        bytes32 skill2 = keccak256(abi.encodePacked("code_execution", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](2);
        skills[0] = skill1;
        skills[1] = skill2;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Verify both skills at once
        bytes32[] memory skillsToVerify = new bytes32[](2);
        skillsToVerify[0] = skill1;
        skillsToVerify[1] = skill2;
        
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = skill2;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = skill1;
        
        bool[] memory results = registry.verifySkills(root, skillsToVerify, proofs);
        
        assertTrue(results[0]);
        assertTrue(results[1]);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_GetSkillByName() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "ipfs://QmWebSearch",
            false
        );
        
        SkillRegistry.Skill memory skill = registry.getSkillByName("web_search", "1.0.0");
        assertEq(skill.skillHash, skillHash);
    }
    
    function test_GetSkillByName_NotFound_Reverts() public {
        vm.expectRevert(SkillRegistry.SkillNotFound.selector);
        registry.getSkillByName("nonexistent", "1.0.0");
    }
    
    function test_GetSkillHash() public view {
        bytes32 hash = registry.getSkillHash("web_search", "1.0.0");
        bytes32 expected = keccak256(abi.encodePacked("web_search", "1.0.0"));
        assertEq(hash, expected);
    }
    
    function test_IsSkillRegistered() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "ipfs://QmWebSearch",
            false
        );
        
        assertTrue(registry.isSkillRegistered(skillHash));
        assertFalse(registry.isSkillRegistered(keccak256("nonexistent")));
    }
    
    function test_GetAllSkills_Pagination() public {
        // Register 5 skills
        for (uint256 i = 0; i < 5; i++) {
            registry.registerSkill(
                string(abi.encodePacked("skill", vm.toString(i))),
                "1.0.0",
                "ipfs://",
                false
            );
        }
        
        assertEq(registry.getAllSkillsCount(), 5);
        
        // Get first 3
        bytes32[] memory first3 = registry.getAllSkills(0, 3);
        assertEq(first3.length, 3);
        
        // Get last 2
        bytes32[] memory last2 = registry.getAllSkills(3, 3);
        assertEq(last2.length, 2);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function testFuzz_SkillHashDeterminism(
        string calldata name,
        string calldata version
    ) public {
        vm.assume(bytes(name).length > 0 && bytes(version).length > 0);
        
        bytes32 hash1 = registry.getSkillHash(name, version);
        bytes32 hash2 = registry.getSkillHash(name, version);
        
        assertEq(hash1, hash2);
        assertEq(hash1, keccak256(abi.encodePacked(name, version)));
    }
}
