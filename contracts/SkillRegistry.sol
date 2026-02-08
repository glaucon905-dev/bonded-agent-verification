// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title SkillRegistry
 * @notice Registry for agent skills/tools with Merkle verification
 * @dev Part of EIP-XXXX: Bonded Agent Verification
 */
contract SkillRegistry {
    
    // ═══════════════════════════════════════════════════════════════
    //                           STRUCTS
    // ═══════════════════════════════════════════════════════════════
    
    struct Skill {
        bytes32 skillHash;        // keccak256(skill_definition)
        string name;              // Human-readable name (e.g., "web_search")
        string version;           // Semantic version (e.g., "1.0.0")
        string specURI;           // IPFS/HTTPS link to full specification
        bool isDeterministic;     // Whether outputs are reproducible
        address registrant;       // Who registered this skill
        uint64 registeredAt;
    }
    
    /// @notice Skill definition schema (stored off-chain, hash committed on-chain)
    /// {
    ///   "name": "web_search",
    ///   "version": "1.0.0",
    ///   "description": "Search the web using Brave API",
    ///   "inputs": {
    ///     "query": { "type": "string", "required": true },
    ///     "count": { "type": "uint8", "default": 10 }
    ///   },
    ///   "outputs": {
    ///     "results": { "type": "SearchResult[]" }
    ///   },
    ///   "deterministic": false,
    ///   "side_effects": ["network_request"],
    ///   "gas_estimate": 0,
    ///   "permissions": ["internet"]
    /// }
    
    // ═══════════════════════════════════════════════════════════════
    //                           STORAGE
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Skill hash => Skill data
    mapping(bytes32 => Skill) public skills;
    
    /// @notice Name => version => skill hash (for lookup)
    mapping(string => mapping(string => bytes32)) public skillsByName;
    
    /// @notice All registered skill hashes
    bytes32[] public allSkills;
    
    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════
    
    event SkillRegistered(
        bytes32 indexed skillHash,
        string indexed name,
        string version,
        string specURI,
        bool isDeterministic
    );
    
    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error SkillAlreadyRegistered();
    error SkillNotFound();
    error InvalidSkillHash();
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Register a new skill definition
     * @param name Human-readable skill name
     * @param version Semantic version
     * @param specURI Link to full specification JSON
     * @param isDeterministic Whether skill outputs are reproducible
     * @return skillHash The unique identifier for the skill
     */
    function registerSkill(
        string calldata name,
        string calldata version,
        string calldata specURI,
        bool isDeterministic
    ) external returns (bytes32 skillHash) {
        // Generate deterministic skill hash
        skillHash = keccak256(abi.encodePacked(name, version));
        
        if (skills[skillHash].registeredAt != 0) {
            revert SkillAlreadyRegistered();
        }
        
        skills[skillHash] = Skill({
            skillHash: skillHash,
            name: name,
            version: version,
            specURI: specURI,
            isDeterministic: isDeterministic,
            registrant: msg.sender,
            registeredAt: uint64(block.timestamp)
        });
        
        skillsByName[name][version] = skillHash;
        allSkills.push(skillHash);
        
        emit SkillRegistered(skillHash, name, version, specURI, isDeterministic);
    }
    
    /**
     * @notice Register multiple skills at once
     */
    function registerSkillsBatch(
        string[] calldata names,
        string[] calldata versions,
        string[] calldata specURIs,
        bool[] calldata isDeterministic
    ) external returns (bytes32[] memory skillHashes) {
        require(
            names.length == versions.length &&
            versions.length == specURIs.length &&
            specURIs.length == isDeterministic.length,
            "Array length mismatch"
        );
        
        skillHashes = new bytes32[](names.length);
        
        for (uint256 i = 0; i < names.length; i++) {
            bytes32 skillHash = keccak256(abi.encodePacked(names[i], versions[i]));
            
            if (skills[skillHash].registeredAt != 0) {
                revert SkillAlreadyRegistered();
            }
            
            skills[skillHash] = Skill({
                skillHash: skillHash,
                name: names[i],
                version: versions[i],
                specURI: specURIs[i],
                isDeterministic: isDeterministic[i],
                registrant: msg.sender,
                registeredAt: uint64(block.timestamp)
            });
            
            skillsByName[names[i]][versions[i]] = skillHash;
            allSkills.push(skillHash);
            skillHashes[i] = skillHash;
            
            emit SkillRegistered(skillHash, names[i], versions[i], specURIs[i], isDeterministic[i]);
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      MERKLE VERIFICATION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Verify a skill is in an agent's skill tree
     * @param skillsRoot The agent's committed skills Merkle root
     * @param skillHash The skill to verify
     * @param merkleProof Proof of inclusion
     * @return isValid True if skill is in the tree
     */
    function verifySkill(
        bytes32 skillsRoot,
        bytes32 skillHash,
        bytes32[] calldata merkleProof
    ) external pure returns (bool isValid) {
        bytes32 leaf = skillHash;
        return MerkleProof.verify(merkleProof, skillsRoot, leaf);
    }
    
    /**
     * @notice Verify multiple skills at once
     */
    function verifySkills(
        bytes32 skillsRoot,
        bytes32[] calldata skillHashes,
        bytes32[][] calldata merkleProofs
    ) external pure returns (bool[] memory results) {
        require(skillHashes.length == merkleProofs.length, "Array length mismatch");
        
        results = new bool[](skillHashes.length);
        
        for (uint256 i = 0; i < skillHashes.length; i++) {
            results[i] = MerkleProof.verify(merkleProofs[i], skillsRoot, skillHashes[i]);
        }
    }
    
    /**
     * @notice Compute skills root from a list of skill hashes
     * @dev For building the Merkle tree off-chain, use this to verify
     */
    function computeSkillsRoot(
        bytes32[] calldata skillHashes
    ) external pure returns (bytes32 root) {
        require(skillHashes.length > 0, "Empty skills list");
        
        // Simple implementation: hash pairs iteratively
        // For production, use a proper Merkle tree library
        bytes32[] memory layer = skillHashes;
        
        while (layer.length > 1) {
            uint256 newLength = (layer.length + 1) / 2;
            bytes32[] memory newLayer = new bytes32[](newLength);
            
            for (uint256 i = 0; i < newLength; i++) {
                uint256 left = i * 2;
                uint256 right = left + 1;
                
                if (right < layer.length) {
                    // Sort to ensure consistency
                    if (layer[left] < layer[right]) {
                        newLayer[i] = keccak256(abi.encodePacked(layer[left], layer[right]));
                    } else {
                        newLayer[i] = keccak256(abi.encodePacked(layer[right], layer[left]));
                    }
                } else {
                    newLayer[i] = layer[left];
                }
            }
            
            layer = newLayer;
        }
        
        return layer[0];
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    
    function getSkill(bytes32 skillHash) external view returns (Skill memory) {
        if (skills[skillHash].registeredAt == 0) revert SkillNotFound();
        return skills[skillHash];
    }
    
    function getSkillByName(
        string calldata name,
        string calldata version
    ) external view returns (Skill memory) {
        bytes32 skillHash = skillsByName[name][version];
        if (skillHash == bytes32(0)) revert SkillNotFound();
        return skills[skillHash];
    }
    
    function getSkillHash(
        string calldata name,
        string calldata version
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, version));
    }
    
    function isSkillRegistered(bytes32 skillHash) external view returns (bool) {
        return skills[skillHash].registeredAt != 0;
    }
    
    function isSkillDeterministic(bytes32 skillHash) external view returns (bool) {
        if (skills[skillHash].registeredAt == 0) revert SkillNotFound();
        return skills[skillHash].isDeterministic;
    }
    
    function getAllSkillsCount() external view returns (uint256) {
        return allSkills.length;
    }
    
    function getAllSkills(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory) {
        uint256 end = offset + limit;
        if (end > allSkills.length) {
            end = allSkills.length;
        }
        
        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allSkills[i];
        }
        
        return result;
    }
}
