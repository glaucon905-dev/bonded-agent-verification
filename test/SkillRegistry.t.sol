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
        string description,
        bytes32 implementationHash,
        string specURI,
        bool isDeterministic,
        address registrant
    );
    
    event SkillUpdated(
        bytes32 indexed skillHash,
        string indexed name,
        string newDescription,
        bytes32 newImplementationHash,
        string newSpecURI
    );
    
    event SkillDeprecated(
        bytes32 indexed skillHash,
        string indexed name,
        string version,
        bytes32 replacedBy
    );
    
    event CategoryCreated(
        string indexed name,
        string description
    );
    
    event SkillCategorized(
        bytes32 indexed skillHash,
        string indexed categoryName
    );
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public owner;
    
    bytes32 constant IMPL_HASH = keccak256("implementation_code_v1");
    bytes32 constant IMPL_HASH_V2 = keccak256("implementation_code_v2");
    
    function setUp() public {
        registry = new SkillRegistry();
        owner = address(this);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_RegisterSkill_FullParams() public {
        vm.prank(alice);
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "Search the web using Brave API",
            IMPL_HASH,
            "ipfs://QmWebSearch",
            false // not deterministic
        );
        
        bytes32 expectedHash = keccak256(abi.encodePacked("web_search", "1.0.0"));
        assertEq(skillHash, expectedHash);
        
        SkillRegistry.Skill memory skill = registry.getSkill(skillHash);
        assertEq(skill.name, "web_search");
        assertEq(skill.version, "1.0.0");
        assertEq(skill.description, "Search the web using Brave API");
        assertEq(skill.implementationHash, IMPL_HASH);
        assertEq(skill.specURI, "ipfs://QmWebSearch");
        assertFalse(skill.isDeterministic);
        assertFalse(skill.deprecated);
        assertEq(skill.registrant, alice);
    }
    
    function test_RegisterSkill_MinimalParams() public {
        vm.prank(alice);
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "ipfs://QmWebSearch",
            false
        );
        
        SkillRegistry.Skill memory skill = registry.getSkill(skillHash);
        assertEq(skill.name, "web_search");
        assertEq(skill.description, ""); // Empty with minimal params
        assertEq(skill.implementationHash, bytes32(0));
    }
    
    function test_RegisterSkill_Deterministic() public {
        bytes32 skillHash = registry.registerSkill(
            "math_eval",
            "1.0.0",
            "Evaluate mathematical expressions",
            IMPL_HASH,
            "ipfs://QmMath",
            true // deterministic
        );
        
        assertTrue(registry.isSkillDeterministic(skillHash));
    }
    
    function test_RegisterSkill_EmitsFullEvent() public {
        bytes32 expectedHash = keccak256(abi.encodePacked("web_search", "1.0.0"));
        
        vm.expectEmit(true, true, true, true);
        emit SkillRegistered(
            expectedHash,
            "web_search",
            "1.0.0",
            "Search the web",
            IMPL_HASH,
            "ipfs://QmWebSearch",
            false,
            address(this)
        );
        
        registry.registerSkill(
            "web_search",
            "1.0.0",
            "Search the web",
            IMPL_HASH,
            "ipfs://QmWebSearch",
            false
        );
    }
    
    function test_RegisterSkill_Duplicate_Reverts() public {
        registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        
        vm.expectRevert(SkillRegistry.SkillAlreadyRegistered.selector);
        registry.registerSkill("web_search", "1.0.0", "ipfs://2", true);
    }
    
    function test_RegisterSkill_DifferentVersions() public {
        bytes32 hash1 = registry.registerSkill(
            "web_search", "1.0.0", "Version 1", IMPL_HASH, "ipfs://1", false
        );
        bytes32 hash2 = registry.registerSkill(
            "web_search", "2.0.0", "Version 2", IMPL_HASH_V2, "ipfs://2", false
        );
        
        assertTrue(hash1 != hash2);
        
        assertEq(registry.getSkill(hash1).version, "1.0.0");
        assertEq(registry.getSkill(hash2).version, "2.0.0");
        
        // Latest should be v2
        SkillRegistry.Skill memory latest = registry.getLatestSkill("web_search");
        assertEq(latest.version, "2.0.0");
    }
    
    function test_RegisterSkillsBatch_FullParams() public {
        string[] memory names = new string[](3);
        names[0] = "web_search";
        names[1] = "code_execution";
        names[2] = "file_read";
        
        string[] memory versions = new string[](3);
        versions[0] = "1.0.0";
        versions[1] = "1.0.0";
        versions[2] = "1.0.0";
        
        string[] memory descriptions = new string[](3);
        descriptions[0] = "Search the web";
        descriptions[1] = "Execute code";
        descriptions[2] = "Read files";
        
        bytes32[] memory implHashes = new bytes32[](3);
        implHashes[0] = keccak256("impl1");
        implHashes[1] = keccak256("impl2");
        implHashes[2] = keccak256("impl3");
        
        string[] memory uris = new string[](3);
        uris[0] = "ipfs://1";
        uris[1] = "ipfs://2";
        uris[2] = "ipfs://3";
        
        bool[] memory deterministic = new bool[](3);
        deterministic[0] = false;
        deterministic[1] = true;
        deterministic[2] = true;
        
        bytes32[] memory hashes = registry.registerSkillsBatch(
            names, versions, descriptions, implHashes, uris, deterministic
        );
        
        assertEq(hashes.length, 3);
        assertEq(registry.getAllSkillsCount(), 3);
        
        // Verify each skill
        SkillRegistry.Skill memory skill = registry.getSkill(hashes[1]);
        assertEq(skill.name, "code_execution");
        assertEq(skill.description, "Execute code");
        assertTrue(skill.isDeterministic);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      UPDATE TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_UpdateSkill_Success() public {
        vm.startPrank(alice);
        bytes32 skillHash = registry.registerSkill(
            "web_search",
            "1.0.0",
            "Old description",
            IMPL_HASH,
            "ipfs://old",
            false
        );
        
        registry.updateSkill(
            skillHash,
            "New improved description",
            IMPL_HASH_V2,
            "ipfs://new"
        );
        vm.stopPrank();
        
        SkillRegistry.Skill memory skill = registry.getSkill(skillHash);
        assertEq(skill.description, "New improved description");
        assertEq(skill.implementationHash, IMPL_HASH_V2);
        assertEq(skill.specURI, "ipfs://new");
    }
    
    function test_UpdateSkill_EmitsEvent() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "Old", IMPL_HASH, "ipfs://old", false
        );
        
        vm.expectEmit(true, true, true, true);
        emit SkillUpdated(
            skillHash,
            "web_search",
            "New description",
            IMPL_HASH_V2,
            "ipfs://new"
        );
        
        registry.updateSkill(skillHash, "New description", IMPL_HASH_V2, "ipfs://new");
    }
    
    function test_UpdateSkill_NotRegistrant_Reverts() public {
        vm.prank(alice);
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "Desc", IMPL_HASH, "ipfs://1", false
        );
        
        vm.prank(bob);
        vm.expectRevert(SkillRegistry.NotRegistrant.selector);
        registry.updateSkill(skillHash, "New", IMPL_HASH_V2, "ipfs://new");
    }
    
    function test_UpdateSkill_Deprecated_Reverts() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "Desc", IMPL_HASH, "ipfs://1", false
        );
        
        registry.deprecateSkill(skillHash, bytes32(0));
        
        vm.expectRevert(SkillRegistry.SkillAlreadyDeprecated.selector);
        registry.updateSkill(skillHash, "New", IMPL_HASH_V2, "ipfs://new");
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      DEPRECATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_DeprecateSkill_Success() public {
        bytes32 v1Hash = registry.registerSkill(
            "web_search", "1.0.0", "V1", IMPL_HASH, "ipfs://1", false
        );
        bytes32 v2Hash = registry.registerSkill(
            "web_search", "2.0.0", "V2", IMPL_HASH_V2, "ipfs://2", false
        );
        
        registry.deprecateSkill(v1Hash, v2Hash);
        
        assertTrue(registry.isSkillDeprecated(v1Hash));
        assertFalse(registry.isSkillDeprecated(v2Hash));
    }
    
    function test_DeprecateSkill_EmitsEvent() public {
        bytes32 v1Hash = registry.registerSkill(
            "web_search", "1.0.0", "V1", IMPL_HASH, "ipfs://1", false
        );
        bytes32 v2Hash = registry.registerSkill(
            "web_search", "2.0.0", "V2", IMPL_HASH_V2, "ipfs://2", false
        );
        
        vm.expectEmit(true, true, true, true);
        emit SkillDeprecated(v1Hash, "web_search", "1.0.0", v2Hash);
        
        registry.deprecateSkill(v1Hash, v2Hash);
    }
    
    function test_DeprecateSkill_UpdatesLatestVersion() public {
        bytes32 v1Hash = registry.registerSkill(
            "web_search", "1.0.0", "V1", IMPL_HASH, "ipfs://1", false
        );
        bytes32 v2Hash = registry.registerSkill(
            "web_search", "2.0.0", "V2", IMPL_HASH_V2, "ipfs://2", false
        );
        
        // v2 is already latest, deprecate v1 pointing to v2
        registry.deprecateSkill(v1Hash, v2Hash);
        
        SkillRegistry.Skill memory latest = registry.getLatestSkill("web_search");
        assertEq(latest.skillHash, v2Hash);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      MERKLE VERIFICATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_ComputeSkillsRoot_SingleSkill() public view {
        bytes32 skillHash = keccak256(abi.encodePacked("web_search", "1.0.0"));
        
        bytes32[] memory skills = new bytes32[](1);
        skills[0] = skillHash;
        
        bytes32 root = registry.computeSkillsRoot(skills);
        
        // Single skill root is just the skill hash
        assertEq(root, skillHash);
    }
    
    function test_ComputeSkillsRoot_TwoSkills() public view {
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
    
    function test_ComputeSkillsRoot_Empty_Reverts() public {
        bytes32[] memory skills = new bytes32[](0);
        
        vm.expectRevert(SkillRegistry.EmptySkillsList.selector);
        registry.computeSkillsRoot(skills);
    }
    
    function test_VerifySkill_TwoSkillTree() public view {
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
    
    function test_VerifySkill_InvalidProof() public view {
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
    
    function test_VerifyRegisteredSkill() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "Desc", IMPL_HASH, "ipfs://1", false
        );
        
        bytes32[] memory skills = new bytes32[](1);
        skills[0] = skillHash;
        bytes32 root = registry.computeSkillsRoot(skills);
        
        bytes32[] memory proof = new bytes32[](0);
        
        (bool inTree, bool isRegistered, bool isDeprecated) = 
            registry.verifyRegisteredSkill(root, skillHash, proof);
        
        assertTrue(inTree);
        assertTrue(isRegistered);
        assertFalse(isDeprecated);
    }
    
    function test_VerifyRegisteredSkill_Deprecated() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "Desc", IMPL_HASH, "ipfs://1", false
        );
        registry.deprecateSkill(skillHash, bytes32(0));
        
        bytes32[] memory skills = new bytes32[](1);
        skills[0] = skillHash;
        bytes32 root = registry.computeSkillsRoot(skills);
        
        bytes32[] memory proof = new bytes32[](0);
        
        (bool inTree, bool isRegistered, bool isDeprecated) = 
            registry.verifyRegisteredSkill(root, skillHash, proof);
        
        assertTrue(inTree);
        assertTrue(isRegistered);
        assertTrue(isDeprecated);
    }
    
    function test_VerifySkills_Batch() public view {
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
    //                      INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_ValidateSkills_AllValid() public {
        bytes32 hash1 = registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        bytes32 hash2 = registry.registerSkill("code_exec", "1.0.0", "ipfs://2", true);
        
        bytes32[] memory skillHashes = new bytes32[](2);
        skillHashes[0] = hash1;
        skillHashes[1] = hash2;
        
        (bool allValid, uint256[] memory invalidSkills) = registry.validateSkills(skillHashes);
        
        assertTrue(allValid);
        assertEq(invalidSkills.length, 0);
    }
    
    function test_ValidateSkills_WithUnregistered() public {
        bytes32 hash1 = registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        bytes32 unregistered = keccak256(abi.encodePacked("fake", "1.0.0"));
        
        bytes32[] memory skillHashes = new bytes32[](2);
        skillHashes[0] = hash1;
        skillHashes[1] = unregistered;
        
        (bool allValid, uint256[] memory invalidSkills) = registry.validateSkills(skillHashes);
        
        assertFalse(allValid);
        assertEq(invalidSkills.length, 1);
        assertEq(invalidSkills[0], 1); // Index of invalid skill
    }
    
    function test_ValidateSkills_WithDeprecated() public {
        bytes32 hash1 = registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        registry.deprecateSkill(hash1, bytes32(0));
        
        bytes32[] memory skillHashes = new bytes32[](1);
        skillHashes[0] = hash1;
        
        (bool allValid, uint256[] memory invalidSkills) = registry.validateSkills(skillHashes);
        
        assertFalse(allValid);
        assertEq(invalidSkills.length, 1);
    }
    
    function test_AreAllSkillsDeterministic_True() public {
        bytes32 hash1 = registry.registerSkill("math", "1.0.0", "ipfs://1", true);
        bytes32 hash2 = registry.registerSkill("hash", "1.0.0", "ipfs://2", true);
        
        bytes32[] memory skillHashes = new bytes32[](2);
        skillHashes[0] = hash1;
        skillHashes[1] = hash2;
        
        assertTrue(registry.areAllSkillsDeterministic(skillHashes));
    }
    
    function test_AreAllSkillsDeterministic_False() public {
        bytes32 hash1 = registry.registerSkill("math", "1.0.0", "ipfs://1", true);
        bytes32 hash2 = registry.registerSkill("web_search", "1.0.0", "ipfs://2", false);
        
        bytes32[] memory skillHashes = new bytes32[](2);
        skillHashes[0] = hash1;
        skillHashes[1] = hash2;
        
        assertFalse(registry.areAllSkillsDeterministic(skillHashes));
    }
    
    function test_GetSkillsInfo() public {
        bytes32 hash1 = registry.registerSkill(
            "web_search", "1.0.0", "Search web", IMPL_HASH, "ipfs://1", false
        );
        bytes32 hash2 = registry.registerSkill(
            "math", "1.0.0", "Math eval", IMPL_HASH, "ipfs://2", true
        );
        
        bytes32[] memory skillHashes = new bytes32[](2);
        skillHashes[0] = hash1;
        skillHashes[1] = hash2;
        
        SkillRegistry.SkillInfo[] memory infos = registry.getSkillsInfo(skillHashes);
        
        assertEq(infos.length, 2);
        assertEq(infos[0].name, "web_search");
        assertFalse(infos[0].isDeterministic);
        assertEq(infos[1].name, "math");
        assertTrue(infos[1].isDeterministic);
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      CATEGORY TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_CreateCategory() public {
        vm.expectEmit(true, true, true, true);
        emit CategoryCreated("networking", "Network-related skills");
        
        registry.createCategory("networking", "Network-related skills");
        
        assertEq(registry.getCategoriesCount(), 1);
    }
    
    function test_AddSkillToCategory() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "ipfs://1", false
        );
        
        registry.createCategory("networking", "Network skills");
        registry.addSkillToCategory(skillHash, "networking");
        
        bytes32[] memory categorySkills = registry.getCategorySkills("networking");
        assertEq(categorySkills.length, 1);
        assertEq(categorySkills[0], skillHash);
    }
    
    function test_AddSkillToCategory_NotFound_Reverts() public {
        bytes32 skillHash = registry.registerSkill(
            "web_search", "1.0.0", "ipfs://1", false
        );
        
        vm.expectRevert(SkillRegistry.CategoryNotFound.selector);
        registry.addSkillToCategory(skillHash, "nonexistent");
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      PERMISSION TESTS
    // ═══════════════════════════════════════════════════════════════
    
    function test_PermissionedRegistration() public {
        registry.setPermissionedRegistration(true);
        
        vm.prank(alice);
        vm.expectRevert(SkillRegistry.NotAuthorized.selector);
        registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        
        // Authorize alice
        registry.authorizeRegistrant(alice);
        
        vm.prank(alice);
        bytes32 hash = registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        assertTrue(hash != bytes32(0));
    }
    
    function test_RevokeRegistrant() public {
        registry.setPermissionedRegistration(true);
        registry.authorizeRegistrant(alice);
        
        // Can register
        vm.prank(alice);
        registry.registerSkill("skill1", "1.0.0", "ipfs://1", false);
        
        // Revoke
        registry.revokeRegistrant(alice);
        
        // Can no longer register
        vm.prank(alice);
        vm.expectRevert(SkillRegistry.NotAuthorized.selector);
        registry.registerSkill("skill2", "1.0.0", "ipfs://2", false);
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
    
    function test_GetLatestSkill() public {
        registry.registerSkill("web_search", "1.0.0", "ipfs://1", false);
        bytes32 latestHash = registry.registerSkill("web_search", "2.0.0", "ipfs://2", false);
        
        SkillRegistry.Skill memory latest = registry.getLatestSkill("web_search");
        assertEq(latest.skillHash, latestHash);
        assertEq(latest.version, "2.0.0");
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
    ) public view {
        vm.assume(bytes(name).length > 0 && bytes(version).length > 0);
        
        bytes32 hash1 = registry.getSkillHash(name, version);
        bytes32 hash2 = registry.getSkillHash(name, version);
        
        assertEq(hash1, hash2);
        assertEq(hash1, keccak256(abi.encodePacked(name, version)));
    }
    
    function testFuzz_RegisterAndRetrieve(
        string calldata name,
        string calldata version,
        string calldata description
    ) public {
        vm.assume(bytes(name).length > 0 && bytes(name).length < 100);
        vm.assume(bytes(version).length > 0 && bytes(version).length < 20);
        vm.assume(bytes(description).length < 500);
        
        bytes32 skillHash = registry.registerSkill(
            name,
            version,
            description,
            IMPL_HASH,
            "ipfs://test",
            true
        );
        
        SkillRegistry.Skill memory skill = registry.getSkill(skillHash);
        assertEq(skill.name, name);
        assertEq(skill.version, version);
        assertEq(skill.description, description);
    }
}
