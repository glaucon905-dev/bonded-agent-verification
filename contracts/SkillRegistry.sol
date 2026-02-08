// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SkillRegistry
 * @notice Registry for agent skills/tools with Merkle verification
 * @dev Part of EIP-XXXX: Bonded Agent Verification
 * 
 * Skills are the atomic capabilities an agent can perform. Each skill is
 * defined by a deterministic hash of (name, version) and includes metadata
 * about its behavior, determinism, and implementation.
 * 
 * Agents commit to a skillsRoot (Merkle root of their available skills) when
 * registering. This allows challengers to verify an agent had access to
 * specific skills without revealing the full skill list.
 */
contract SkillRegistry is Ownable {
    
    constructor() Ownable(msg.sender) {}
    
    // ═══════════════════════════════════════════════════════════════
    //                           STRUCTS
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Full skill definition
    struct Skill {
        bytes32 skillHash;          // keccak256(name, version) - unique identifier
        string name;                // Human-readable name (e.g., "web_search")
        string version;             // Semantic version (e.g., "1.0.0")
        string description;         // Human-readable description
        bytes32 implementationHash; // keccak256 of skill implementation/code
        string specURI;             // IPFS/HTTPS link to full specification JSON
        bool isDeterministic;       // Whether outputs are reproducible given same input
        address registrant;         // Who registered this skill
        uint64 registeredAt;        // Timestamp of registration
        uint64 lastUpdatedAt;       // Timestamp of last metadata update
        bool deprecated;            // Whether skill is deprecated (superseded by new version)
    }
    
    /// @notice Compact struct for gas-efficient reads
    struct SkillInfo {
        bytes32 skillHash;
        string name;
        string version;
        bool isDeterministic;
        bool deprecated;
    }
    
    /// @notice Skill category for organization
    struct SkillCategory {
        string name;
        string description;
        bytes32[] skillHashes;
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
    ///   "permissions": ["internet"],
    ///   "implementation_hash": "0x..."
    /// }
    
    // ═══════════════════════════════════════════════════════════════
    //                           STORAGE
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Skill hash => Skill data
    mapping(bytes32 => Skill) public skills;
    
    /// @notice Name => version => skill hash (for lookup)
    mapping(string => mapping(string => bytes32)) public skillsByName;
    
    /// @notice Name => latest version hash
    mapping(string => bytes32) public latestVersion;
    
    /// @notice Category name => category data
    mapping(string => SkillCategory) public categories;
    
    /// @notice All registered skill hashes
    bytes32[] public allSkills;
    
    /// @notice All category names
    string[] public allCategories;
    
    /// @notice Authorized registrants (empty = anyone can register)
    mapping(address => bool) public authorizedRegistrants;
    
    /// @notice Whether registration is permissioned
    bool public permissionedRegistration;
    
    // ═══════════════════════════════════════════════════════════════
    //                           EVENTS
    // ═══════════════════════════════════════════════════════════════
    
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
    
    event RegistrantAuthorized(address indexed registrant);
    event RegistrantRevoked(address indexed registrant);
    
    // ═══════════════════════════════════════════════════════════════
    //                           ERRORS
    // ═══════════════════════════════════════════════════════════════
    
    error SkillAlreadyRegistered();
    error SkillNotFound();
    error InvalidSkillHash();
    error NotRegistrant();
    error NotAuthorized();
    error CategoryNotFound();
    error SkillAlreadyDeprecated();
    error EmptySkillsList();
    error ArrayLengthMismatch();
    
    // ═══════════════════════════════════════════════════════════════
    //                           MODIFIERS
    // ═══════════════════════════════════════════════════════════════
    
    modifier onlySkillRegistrant(bytes32 skillHash) {
        if (skills[skillHash].registrant != msg.sender) revert NotRegistrant();
        _;
    }
    
    modifier canRegister() {
        if (permissionedRegistration && !authorizedRegistrants[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      REGISTRATION
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Register a new skill definition
     * @param name Human-readable skill name
     * @param version Semantic version
     * @param description Human-readable description of what the skill does
     * @param implementationHash keccak256 of the skill's implementation code
     * @param specURI Link to full specification JSON
     * @param isDeterministic Whether skill outputs are reproducible
     * @return skillHash The unique identifier for the skill
     */
    function registerSkill(
        string calldata name,
        string calldata version,
        string calldata description,
        bytes32 implementationHash,
        string calldata specURI,
        bool isDeterministic
    ) external canRegister returns (bytes32 skillHash) {
        // Generate deterministic skill hash
        skillHash = keccak256(abi.encodePacked(name, version));
        
        if (skills[skillHash].registeredAt != 0) {
            revert SkillAlreadyRegistered();
        }
        
        skills[skillHash] = Skill({
            skillHash: skillHash,
            name: name,
            version: version,
            description: description,
            implementationHash: implementationHash,
            specURI: specURI,
            isDeterministic: isDeterministic,
            registrant: msg.sender,
            registeredAt: uint64(block.timestamp),
            lastUpdatedAt: uint64(block.timestamp),
            deprecated: false
        });
        
        skillsByName[name][version] = skillHash;
        allSkills.push(skillHash);
        
        // Update latest version if this is a newer version
        bytes32 currentLatest = latestVersion[name];
        if (currentLatest == bytes32(0)) {
            latestVersion[name] = skillHash;
        }
        // Note: Version comparison would need semantic versioning logic
        // For now, latest is just the most recently registered
        latestVersion[name] = skillHash;
        
        emit SkillRegistered(
            skillHash,
            name,
            version,
            description,
            implementationHash,
            specURI,
            isDeterministic,
            msg.sender
        );
    }
    
    /**
     * @notice Register a skill with minimal parameters (backwards compatible)
     */
    function registerSkill(
        string calldata name,
        string calldata version,
        string calldata specURI,
        bool isDeterministic
    ) external canRegister returns (bytes32 skillHash) {
        skillHash = keccak256(abi.encodePacked(name, version));
        
        if (skills[skillHash].registeredAt != 0) {
            revert SkillAlreadyRegistered();
        }
        
        skills[skillHash] = Skill({
            skillHash: skillHash,
            name: name,
            version: version,
            description: "",
            implementationHash: bytes32(0),
            specURI: specURI,
            isDeterministic: isDeterministic,
            registrant: msg.sender,
            registeredAt: uint64(block.timestamp),
            lastUpdatedAt: uint64(block.timestamp),
            deprecated: false
        });
        
        skillsByName[name][version] = skillHash;
        allSkills.push(skillHash);
        latestVersion[name] = skillHash;
        
        emit SkillRegistered(
            skillHash,
            name,
            version,
            "",
            bytes32(0),
            specURI,
            isDeterministic,
            msg.sender
        );
    }
    
    /**
     * @notice Register multiple skills at once
     */
    function registerSkillsBatch(
        string[] calldata names,
        string[] calldata versions,
        string[] calldata descriptions,
        bytes32[] calldata implementationHashes,
        string[] calldata specURIs,
        bool[] calldata isDeterministic
    ) external canRegister returns (bytes32[] memory skillHashes) {
        if (names.length != versions.length ||
            versions.length != descriptions.length ||
            descriptions.length != implementationHashes.length ||
            implementationHashes.length != specURIs.length ||
            specURIs.length != isDeterministic.length) {
            revert ArrayLengthMismatch();
        }
        
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
                description: descriptions[i],
                implementationHash: implementationHashes[i],
                specURI: specURIs[i],
                isDeterministic: isDeterministic[i],
                registrant: msg.sender,
                registeredAt: uint64(block.timestamp),
                lastUpdatedAt: uint64(block.timestamp),
                deprecated: false
            });
            
            skillsByName[names[i]][versions[i]] = skillHash;
            allSkills.push(skillHash);
            latestVersion[names[i]] = skillHash;
            skillHashes[i] = skillHash;
            
            emit SkillRegistered(
                skillHash,
                names[i],
                versions[i],
                descriptions[i],
                implementationHashes[i],
                specURIs[i],
                isDeterministic[i],
                msg.sender
            );
        }
    }
    
    /**
     * @notice Backwards compatible batch registration
     */
    function registerSkillsBatch(
        string[] calldata names,
        string[] calldata versions,
        string[] calldata specURIs,
        bool[] calldata isDeterministic
    ) external canRegister returns (bytes32[] memory skillHashes) {
        if (names.length != versions.length ||
            versions.length != specURIs.length ||
            specURIs.length != isDeterministic.length) {
            revert ArrayLengthMismatch();
        }
        
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
                description: "",
                implementationHash: bytes32(0),
                specURI: specURIs[i],
                isDeterministic: isDeterministic[i],
                registrant: msg.sender,
                registeredAt: uint64(block.timestamp),
                lastUpdatedAt: uint64(block.timestamp),
                deprecated: false
            });
            
            skillsByName[names[i]][versions[i]] = skillHash;
            allSkills.push(skillHash);
            latestVersion[names[i]] = skillHash;
            skillHashes[i] = skillHash;
            
            emit SkillRegistered(
                skillHash,
                names[i],
                versions[i],
                "",
                bytes32(0),
                specURIs[i],
                isDeterministic[i],
                msg.sender
            );
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      UPDATES
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Update skill metadata (only by original registrant)
     * @dev Does not change the skillHash - only metadata can be updated
     */
    function updateSkill(
        bytes32 skillHash,
        string calldata newDescription,
        bytes32 newImplementationHash,
        string calldata newSpecURI
    ) external onlySkillRegistrant(skillHash) {
        Skill storage skill = skills[skillHash];
        if (skill.registeredAt == 0) revert SkillNotFound();
        if (skill.deprecated) revert SkillAlreadyDeprecated();
        
        skill.description = newDescription;
        skill.implementationHash = newImplementationHash;
        skill.specURI = newSpecURI;
        skill.lastUpdatedAt = uint64(block.timestamp);
        
        emit SkillUpdated(
            skillHash,
            skill.name,
            newDescription,
            newImplementationHash,
            newSpecURI
        );
    }
    
    /**
     * @notice Deprecate a skill and point to its replacement
     */
    function deprecateSkill(
        bytes32 skillHash,
        bytes32 replacedByHash
    ) external onlySkillRegistrant(skillHash) {
        Skill storage skill = skills[skillHash];
        if (skill.registeredAt == 0) revert SkillNotFound();
        if (skill.deprecated) revert SkillAlreadyDeprecated();
        
        skill.deprecated = true;
        skill.lastUpdatedAt = uint64(block.timestamp);
        
        // Update latest version to replacement if provided
        if (replacedByHash != bytes32(0)) {
            Skill storage replacement = skills[replacedByHash];
            if (replacement.registeredAt != 0 && 
                keccak256(bytes(replacement.name)) == keccak256(bytes(skill.name))) {
                latestVersion[skill.name] = replacedByHash;
            }
        }
        
        emit SkillDeprecated(skillHash, skill.name, skill.version, replacedByHash);
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
        if (skillHashes.length != merkleProofs.length) revert ArrayLengthMismatch();
        
        results = new bool[](skillHashes.length);
        
        for (uint256 i = 0; i < skillHashes.length; i++) {
            results[i] = MerkleProof.verify(merkleProofs[i], skillsRoot, skillHashes[i]);
        }
    }
    
    /**
     * @notice Verify a skill is in tree AND is registered
     * @dev Use this for full validation (skill exists + agent has it)
     */
    function verifyRegisteredSkill(
        bytes32 skillsRoot,
        bytes32 skillHash,
        bytes32[] calldata merkleProof
    ) external view returns (bool inTree, bool isRegistered, bool isDeprecated) {
        inTree = MerkleProof.verify(merkleProof, skillsRoot, skillHash);
        isRegistered = skills[skillHash].registeredAt != 0;
        isDeprecated = skills[skillHash].deprecated;
    }
    
    /**
     * @notice Compute skills root from a list of skill hashes
     * @dev For building the Merkle tree off-chain, use this to verify
     */
    function computeSkillsRoot(
        bytes32[] calldata skillHashes
    ) external pure returns (bytes32 root) {
        if (skillHashes.length == 0) revert EmptySkillsList();
        
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
    
    /**
     * @notice Generate a Merkle proof for a skill at a given index
     * @dev Helper for off-chain proof generation verification
     */
    function generateMerkleProof(
        bytes32[] calldata skillHashes,
        uint256 index
    ) external pure returns (bytes32[] memory proof) {
        if (skillHashes.length == 0) revert EmptySkillsList();
        if (index >= skillHashes.length) revert InvalidSkillHash();
        
        // Calculate proof depth
        uint256 depth = 0;
        uint256 n = skillHashes.length;
        while (n > 1) {
            n = (n + 1) / 2;
            depth++;
        }
        
        proof = new bytes32[](depth);
        bytes32[] memory layer = skillHashes;
        uint256 idx = index;
        
        for (uint256 d = 0; d < depth; d++) {
            uint256 pairIdx = idx % 2 == 0 ? idx + 1 : idx - 1;
            
            if (pairIdx < layer.length) {
                proof[d] = layer[pairIdx];
            } else {
                proof[d] = layer[idx]; // Odd leaf promotes itself
            }
            
            // Build next layer and update index
            uint256 newLength = (layer.length + 1) / 2;
            bytes32[] memory newLayer = new bytes32[](newLength);
            
            for (uint256 i = 0; i < newLength; i++) {
                uint256 left = i * 2;
                uint256 right = left + 1;
                
                if (right < layer.length) {
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
            idx = idx / 2;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      INTEGRATION WITH BONDED AGENT REGISTRY
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Validate that all skills in a list are registered
     * @param skillHashes Array of skill hashes to validate
     * @return allValid True if all skills are registered and not deprecated
     * @return invalidSkills Indices of invalid skills (empty if all valid)
     */
    function validateSkills(
        bytes32[] calldata skillHashes
    ) external view returns (bool allValid, uint256[] memory invalidSkills) {
        uint256 invalidCount = 0;
        uint256[] memory tempInvalid = new uint256[](skillHashes.length);
        
        for (uint256 i = 0; i < skillHashes.length; i++) {
            Skill storage skill = skills[skillHashes[i]];
            if (skill.registeredAt == 0 || skill.deprecated) {
                tempInvalid[invalidCount] = i;
                invalidCount++;
            }
        }
        
        if (invalidCount == 0) {
            allValid = true;
            invalidSkills = new uint256[](0);
        } else {
            allValid = false;
            invalidSkills = new uint256[](invalidCount);
            for (uint256 i = 0; i < invalidCount; i++) {
                invalidSkills[i] = tempInvalid[i];
            }
        }
    }
    
    /**
     * @notice Check if all skills in a skills root are deterministic
     * @dev For high-stakes tasks requiring reproducibility
     */
    function areAllSkillsDeterministic(
        bytes32[] calldata skillHashes
    ) external view returns (bool) {
        for (uint256 i = 0; i < skillHashes.length; i++) {
            Skill storage skill = skills[skillHashes[i]];
            if (skill.registeredAt == 0 || !skill.isDeterministic) {
                return false;
            }
        }
        return true;
    }
    
    /**
     * @notice Get skills info for agent display
     * @param skillHashes Array of skill hashes
     * @return infos Compact skill information array
     */
    function getSkillsInfo(
        bytes32[] calldata skillHashes
    ) external view returns (SkillInfo[] memory infos) {
        infos = new SkillInfo[](skillHashes.length);
        
        for (uint256 i = 0; i < skillHashes.length; i++) {
            Skill storage skill = skills[skillHashes[i]];
            infos[i] = SkillInfo({
                skillHash: skillHashes[i],
                name: skill.name,
                version: skill.version,
                isDeterministic: skill.isDeterministic,
                deprecated: skill.deprecated
            });
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      CATEGORIES
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Create a skill category
     */
    function createCategory(
        string calldata name,
        string calldata description
    ) external onlyOwner {
        categories[name] = SkillCategory({
            name: name,
            description: description,
            skillHashes: new bytes32[](0)
        });
        allCategories.push(name);
        
        emit CategoryCreated(name, description);
    }
    
    /**
     * @notice Add a skill to a category
     */
    function addSkillToCategory(
        bytes32 skillHash,
        string calldata categoryName
    ) external onlyOwner {
        if (skills[skillHash].registeredAt == 0) revert SkillNotFound();
        if (bytes(categories[categoryName].name).length == 0) revert CategoryNotFound();
        
        categories[categoryName].skillHashes.push(skillHash);
        
        emit SkillCategorized(skillHash, categoryName);
    }
    
    /**
     * @notice Get all skills in a category
     */
    function getCategorySkills(
        string calldata categoryName
    ) external view returns (bytes32[] memory) {
        if (bytes(categories[categoryName].name).length == 0) revert CategoryNotFound();
        return categories[categoryName].skillHashes;
    }
    
    // ═══════════════════════════════════════════════════════════════
    //                      ADMIN
    // ═══════════════════════════════════════════════════════════════
    
    /**
     * @notice Enable/disable permissioned registration
     */
    function setPermissionedRegistration(bool enabled) external onlyOwner {
        permissionedRegistration = enabled;
    }
    
    /**
     * @notice Authorize an address to register skills
     */
    function authorizeRegistrant(address registrant) external onlyOwner {
        authorizedRegistrants[registrant] = true;
        emit RegistrantAuthorized(registrant);
    }
    
    /**
     * @notice Revoke registration authorization
     */
    function revokeRegistrant(address registrant) external onlyOwner {
        authorizedRegistrants[registrant] = false;
        emit RegistrantRevoked(registrant);
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
    
    function getLatestSkill(
        string calldata name
    ) external view returns (Skill memory) {
        bytes32 skillHash = latestVersion[name];
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
    
    function isSkillDeprecated(bytes32 skillHash) external view returns (bool) {
        if (skills[skillHash].registeredAt == 0) revert SkillNotFound();
        return skills[skillHash].deprecated;
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
    
    function getCategoriesCount() external view returns (uint256) {
        return allCategories.length;
    }
}
