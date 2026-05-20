// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Monad Fitness Platform
 * @dev A comprehensive Web3 fitness platform integrating Soulbound Tokens (SBT),
 * Stake-to-Commit mechanics, and a Premium Coaching module. Built for the Monad Network.
 */
contract MonadFitnessPlatform is ERC721, AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant GYM_ROLE = keccak256("GYM_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- State Variables ---
    uint256 private _nextTokenId;
    address payable public treasury;
    uint256 public disciplineRewardPool;

    // Core Data Structures
    struct FitnessProfile {
        uint256 totalCheckIns;
        uint256 streakDays;
        uint256 lastCheckInTime;
        uint256 maxBench;
        uint256 maxSquat;
        // Mapping of achievement ID to completion status (e.g., 1 = "Iron Lifter", 2 = "30-Day Streak")
        mapping(uint256 => bool) achievements;
    }

    struct Commitment {
        uint256 targetCheckIns;
        uint256 stakeAmount;
        uint256 startTime;
        uint256 startCheckIns; // Baseline check-ins at the start
        bool active;
    }

    struct Coach {
        bool isVerified;
        uint256 subscriptionExpiry;
        uint256 fee; // Coaching fee per session/period in native MONAD
    }

    struct Brand {
        string name;
        bool isRegistered;
    }

    // Mappings
    mapping(uint256 => FitnessProfile) private _profiles;
    mapping(address => uint256) public addressToTokenId;
    mapping(address => Commitment) public commitments;
    mapping(address => Coach) public coaches;
    mapping(address => Brand) public brands;

    // Constants & Configuration
    uint256 public constant COACH_PLATFORM_FEE_PERCENT = 3;
    uint256 public constant STAKE_PLATFORM_FEE_PERCENT = 2;
    uint256 public constant SLASH_TREASURY_PERCENT = 50;
    uint256 public constant SLASH_POOL_PERCENT = 50; // The remaining 50%
    uint256 public constant COMMITMENT_DURATION = 7 days;
    uint256 public constant CHECK_IN_COOLDOWN = 12 hours; // Prevent spam check-ins
    uint256 public constant STREAK_BREAK_TIME = 48 hours; // Max time before streak is reset

    // --- Events ---
    event ProfileMinted(address indexed user, uint256 tokenId);
    event CheckInVerified(address indexed user, uint256 totalCheckIns, uint256 streakDays);
    event AchievementUnlocked(address indexed user, uint256 achievementId);
    event WorkoutSaved(address indexed user, uint256 bench, uint256 squat);
    
    event BrandRegistered(address indexed brand, string name);
    event DiscountValidated(address indexed brand, address indexed user, uint256 requirementId);

    event CommitmentCreated(address indexed user, uint256 target, uint256 stakeAmount);
    event CommitmentCompleted(address indexed user, uint256 refundAmount);
    event CommitmentSlashed(address indexed user, uint256 slashedAmount);
    
    event CoachRegistered(address indexed coach, uint256 expiry, uint256 fee);
    event CoachingPurchased(address indexed user, address indexed coach, uint256 amount);

    // --- Modifiers ---
    modifier hasSBT(address user) {
        require(addressToTokenId[user] != 0, "User must hold an active SBT profile");
        _;
    }

    /**
     * @dev Constructor
     * @param _treasury Address of the platform treasury to receive fees and slashes
     */
    constructor(address payable _treasury) ERC721("Monad Fitness Profile", "MFP") {
        require(_treasury != address(0), "Invalid treasury address");
        treasury = _treasury;
        
        // Setup initial admin role
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // =========================================================================
    // 1. CORE MECHANICS & SOULBOUND TOKENS (SBT)
    // =========================================================================

    /**
     * @dev Users mint their fitness profile SBT. Only one per address.
     */
    function mintProfileSBT() external {
        require(addressToTokenId[msg.sender] == 0, "Profile SBT already exists for this address");
        
        _nextTokenId++;
        uint256 tokenId = _nextTokenId;
        addressToTokenId[msg.sender] = tokenId;
        
        _safeMint(msg.sender, tokenId);
        emit ProfileMinted(msg.sender, tokenId);
    }

    /**
     * @dev Overrides ERC721 `_update` logic to make the token Soulbound.
     * Note: This uses OpenZeppelin v5.x logic. If using v4.x, use `_beforeTokenTransfer`.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        // Restrict transfer to only minting (from == 0) and burning (to == 0)
        require(from == address(0) || to == address(0), "SBT: Token is non-transferable");
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev User self-reports a check-in.
     */
    function checkIn() external hasSBT(msg.sender) {
        uint256 tokenId = addressToTokenId[msg.sender];
        FitnessProfile storage profile = _profiles[tokenId];
        
        // Cooldown enforcement
        require(block.timestamp >= profile.lastCheckInTime + CHECK_IN_COOLDOWN, "Check-in on cooldown");
        
        // Update Streak
        if (block.timestamp <= profile.lastCheckInTime + STREAK_BREAK_TIME) {
            profile.streakDays++;
        } else {
            profile.streakDays = 1; // Streak broken, reset to 1
        }
        
        profile.totalCheckIns++;
        profile.lastCheckInTime = block.timestamp;
        
        // Trigger generic achievements
        if (profile.totalCheckIns >= 50 && !profile.achievements[1]) {
            profile.achievements[1] = true; // 1 = "Iron Lifter"
            emit AchievementUnlocked(msg.sender, 1);
        }
        if (profile.streakDays >= 30 && !profile.achievements[2]) {
            profile.achievements[2] = true; // 2 = "30-Day Streak"
            emit AchievementUnlocked(msg.sender, 2);
        }

        emit CheckInVerified(msg.sender, profile.totalCheckIns, profile.streakDays);
    }

    /**
     * @dev Saves specific workout stats for an athlete.
     * Updates personal records for bench and squat.
     * @param _bench Bench press weight
     * @param _squat Squat weight
     */
    function saveWorkout(uint256 _bench, uint256 _squat) external hasSBT(msg.sender) {
        uint256 tokenId = addressToTokenId[msg.sender];
        FitnessProfile storage profile = _profiles[tokenId];
        
        if (_bench > profile.maxBench) {
            profile.maxBench = _bench;
        }
        if (_squat > profile.maxSquat) {
            profile.maxSquat = _squat;
        }
        
        emit WorkoutSaved(msg.sender, _bench, _squat);
    }

    /**
     * @dev Returns athlete core stats, explicitly matching the requested ABI format.
     * @param _athlete Address of the athlete to query.
     * @return (totalCheckIns, maxBench, maxSquat)
     */
    function getAthleteData(address _athlete) external view returns (uint256, uint256, uint256) {
        uint256 tokenId = addressToTokenId[_athlete];
        require(tokenId != 0, "No profile found");
        FitnessProfile storage profile = _profiles[tokenId];
        return (profile.totalCheckIns, profile.maxBench, profile.maxSquat);
    }

    function hasAchievement(address user, uint256 achievementId) external view returns (bool) {
        uint256 tokenId = addressToTokenId[user];
        if (tokenId == 0) return false;
        return _profiles[tokenId].achievements[achievementId];
    }

    // Required override for AccessControl + ERC721 compatibility
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }


    // =========================================================================
    // 2. BUSINESS MODEL 1: B2B ADVERTISING & LOYALTY MODULE
    // =========================================================================

    /**
     * @dev External brands register on-chain to gain access to loyalty verification.
     */
    function registerBrand(string calldata name) external {
        require(!brands[msg.sender].isRegistered, "Brand already registered");
        brands[msg.sender] = Brand(name, true);
        emit BrandRegistered(msg.sender, name);
    }

    /**
     * @dev Brands check if a user has a specific achievement to grant an off-chain discount.
     * @param user User to query
     * @param alternativeRequirementId The achievement ID required (0 = just requires SBT)
     */
    function validateDiscount(address user, uint256 alternativeRequirementId) external returns (bool) {
        require(brands[msg.sender].isRegistered, "Caller is not a registered brand");
        uint256 tokenId = addressToTokenId[user];
        
        if (tokenId == 0) return false;
        
        bool isValid = false;
        if (alternativeRequirementId == 0) {
            isValid = true; // Just holding the SBT grants the discount
        } else {
            isValid = _profiles[tokenId].achievements[alternativeRequirementId];
        }

        if (isValid) {
            emit DiscountValidated(msg.sender, user, alternativeRequirementId);
        }
        
        return isValid;
    }


    // =========================================================================
    // 3. BUSINESS MODEL 2: STAKE-TO-COMMIT (DISCIPLINE POOL)
    // =========================================================================

    /**
     * @dev Users lock native MONAD to commit to a check-in target over 7 days.
     */
    function createCommitment(uint256 targetCheckIns) external payable nonReentrant hasSBT(msg.sender) {
        require(!commitments[msg.sender].active, "Commitment already active");
        require(msg.value > 0, "Stake amount must be > 0");
        require(targetCheckIns > 0, "Target check-ins must be > 0");
        
        uint256 currentCheckIns = _profiles[addressToTokenId[msg.sender]].totalCheckIns;

        commitments[msg.sender] = Commitment({
            targetCheckIns: targetCheckIns,
            stakeAmount: msg.value,
            startTime: block.timestamp,
            startCheckIns: currentCheckIns,
            active: true
        });

        emit CommitmentCreated(msg.sender, targetCheckIns, msg.value);
    }

    /**
     * @dev Evaluates the commitment after 7 days. Returns stake if successful, slashes if failed.
     */
    function claimOrSlashCommitment(address user) external nonReentrant {
        Commitment storage commitment = commitments[user];
        require(commitment.active, "No active commitment");
        require(block.timestamp >= commitment.startTime + COMMITMENT_DURATION, "Commitment 7-day period not over");

        uint256 tokenId = addressToTokenId[user];
        uint256 currentCheckIns = _profiles[tokenId].totalCheckIns;
        uint256 checkInsDone = currentCheckIns - commitment.startCheckIns;

        commitment.active = false;
        uint256 stake = commitment.stakeAmount;

        if (checkInsDone >= commitment.targetCheckIns) {
            // Target hit: Refund user minus platform fee
            uint256 platformFee = (stake * STAKE_PLATFORM_FEE_PERCENT) / 100;
            uint256 refund = stake - platformFee;
            
            _safeTransfer(treasury, platformFee);
            _safeTransfer(payable(user), refund);

            emit CommitmentCompleted(user, refund);
        } else {
            // Target missed: Slash stake
            uint256 toTreasury = (stake * SLASH_TREASURY_PERCENT) / 100;
            uint256 toPool = stake - toTreasury;

            disciplineRewardPool += toPool;
            _safeTransfer(treasury, toTreasury);

            emit CommitmentSlashed(user, stake);
        }
    }

    /**
     * @dev Distributes slashed discipline rewards to top performers. Admin only.
     */
    function distributeDisciplineRewards(address[] calldata winners, uint256[] calldata amounts) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(winners.length == amounts.length, "Mismatched array lengths");
        
        uint256 totalDistribution = 0;
        for(uint i = 0; i < amounts.length; i++) {
            totalDistribution += amounts[i];
        }
        
        require(totalDistribution <= disciplineRewardPool, "Insufficient pool balance");
        disciplineRewardPool -= totalDistribution;

        for(uint i = 0; i < winners.length; i++) {
            _safeTransfer(payable(winners[i]), amounts[i]);
        }
    }


    // =========================================================================
    // 4. BUSINESS MODEL 3: PREMIUM WEB3 COACHING & PT CV
    // =========================================================================

    /**
     * @dev Coaches pay a fee to be listed for a specific duration.
     * @param subscriptionDuration Duration in seconds (e.g., 30 days)
     * @param sessionFee Cost for a user to buy this coach's services
     */
    function registerCoach(uint256 subscriptionDuration, uint256 sessionFee) external payable hasSBT(msg.sender) {
        // e.g., 1 MONAD per 30 days standard subscription. Change logic as needed.
        uint256 requiredFee = (subscriptionDuration / 30 days) * 1 ether; 
        require(msg.value >= requiredFee, "Insufficient subscription fee");
        
        _safeTransfer(treasury, msg.value);

        Coach storage coach = coaches[msg.sender];
        coach.isVerified = true;
        // Extend existing expiry if active, otherwise start from now
        if (coach.subscriptionExpiry > block.timestamp) {
            coach.subscriptionExpiry += subscriptionDuration;
        } else {
            coach.subscriptionExpiry = block.timestamp + subscriptionDuration;
        }
        coach.fee = sessionFee;

        emit CoachRegistered(msg.sender, coach.subscriptionExpiry, sessionFee);
    }

    /**
     * @dev Coach updates their session rate.
     */
    function updateCoachFee(uint256 newFee) external {
        require(coaches[msg.sender].isVerified, "Not a verified coach");
        coaches[msg.sender].fee = newFee;
    }

    /**
     * @dev Users pay the coach. Platform takes a commission.
     */
    function purchaseCoaching(address coach) external payable nonReentrant {
        Coach storage coachData = coaches[coach];
        require(coachData.isVerified, "Not a verified coach");
        require(block.timestamp <= coachData.subscriptionExpiry, "Coach subscription has expired");
        require(msg.value == coachData.fee, "Incorrect payment amount");

        uint256 platformFee = (msg.value * COACH_PLATFORM_FEE_PERCENT) / 100;
        uint256 coachPayment = msg.value - platformFee;

        _safeTransfer(treasury, platformFee);
        _safeTransfer(payable(coach), coachPayment);

        emit CoachingPurchased(msg.sender, coach, msg.value);
    }

    // =========================================================================
    // INTERNAL UTILITIES
    // =========================================================================

    function _safeTransfer(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Native token transfer failed");
    }
}
