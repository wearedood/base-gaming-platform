// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./GameToken.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title GamePlatform
 * @dev Main gaming platform contract for Base Gaming Platform
 * Features:
 * - Tournament management with entry fees and prize pools
 * - Player statistics and leaderboards
 * - Achievement system with NFT rewards
 * - Game session tracking and validation
 * - Anti-cheat mechanisms
 * - Revenue sharing for game developers
 */
contract GamePlatform is ReentrancyGuard, Ownable, Pausable {
    using Counters for Counters.Counter;
    
    GameToken public gameToken;
    
    // Counters
    Counters.Counter private _tournamentIds;
    Counters.Counter private _gameIds;
    Counters.Counter private _sessionIds;
    
    // Tournament Structure
    struct Tournament {
        uint256 id;
        string name;
        uint256 entryFee;
        uint256 prizePool;
        uint256 maxPlayers;
        uint256 currentPlayers;
        uint256 startTime;
        uint256 endTime;
        address[] participants;
        address[] winners;
        uint256[] prizes;
        bool isActive;
        bool isFinished;
        TournamentType tournamentType;
    }
    
    enum TournamentType { BATTLE_ROYALE, TEAM_DEATHMATCH, RACING, PUZZLE, STRATEGY }
    
    // Game Structure
    struct Game {
        uint256 id;
        string name;
        address developer;
        uint256 revenueShare; // Percentage (0-100)
        bool isActive;
        uint256 totalSessions;
        uint256 totalRevenue;
        mapping(address => uint256) playerScores;
        mapping(address => uint256) playerSessions;
    }
    
    // Player Statistics
    struct PlayerStats {
        uint256 totalGamesPlayed;
        uint256 totalWins;
        uint256 totalEarnings;
        uint256 currentStreak;
        uint256 bestStreak;
        uint256 level;
        uint256 experience;
        uint256[] achievementIds;
        mapping(uint256 => uint256) gameSpecificStats;
    }
    
    // Game Session
    struct GameSession {
        uint256 id;
        uint256 gameId;
        address player;
        uint256 startTime;
        uint256 endTime;
        uint256 score;
        uint256 reward;
        bool isValidated;
        bytes32 sessionHash;
    }
    
    // Achievement System
    struct Achievement {
        uint256 id;
        string name;
        string description;
        uint256 requiredValue;
        AchievementType achievementType;
        uint256 reward;
        bool isActive;
    }
    
    enum AchievementType { GAMES_PLAYED, WINS, STREAK, SCORE, EARNINGS, LEVEL }
    
    // Mappings
    mapping(uint256 => Tournament) public tournaments;
    mapping(uint256 => Game) public games;
    mapping(uint256 => GameSession) public gameSessions;
    mapping(uint256 => Achievement) public achievements;
    mapping(address => PlayerStats) public playerStats;
    mapping(address => mapping(uint256 => bool)) public playerAchievements;
    mapping(address => bool) public authorizedValidators;
    mapping(bytes32 => bool) public usedSessionHashes;
    
    // Platform Settings
    uint256 public platformFee = 500; // 5%
    uint256 public constant MAX_PLATFORM_FEE = 1000; // 10%
    address public treasuryWallet;
    uint256 public minTournamentFee = 10 * 10**18; // 10 tokens
    uint256 public maxTournamentDuration = 7 days;
    
    // Events
    event TournamentCreated(uint256 indexed tournamentId, string name, uint256 entryFee, uint256 maxPlayers);
    event TournamentJoined(uint256 indexed tournamentId, address indexed player);
    event TournamentFinished(uint256 indexed tournamentId, address[] winners, uint256[] prizes);
    event GameRegistered(uint256 indexed gameId, string name, address indexed developer);
    event GameSessionStarted(uint256 indexed sessionId, uint256 indexed gameId, address indexed player);
    event GameSessionFinished(uint256 indexed sessionId, uint256 score, uint256 reward);
    event AchievementUnlocked(address indexed player, uint256 indexed achievementId, uint256 reward);
    event PlayerLevelUp(address indexed player, uint256 newLevel);
    event RevenueDistributed(uint256 indexed gameId, address indexed developer, uint256 amount);
    
    constructor(address _gameToken, address _treasuryWallet) {
        gameToken = GameToken(_gameToken);
        treasuryWallet = _treasuryWallet;
    }
    
    // Tournament Functions
    
    /**
     * @dev Create a new tournament
     */
    function createTournament(
        string memory name,
        uint256 entryFee,
        uint256 maxPlayers,
        uint256 duration,
        TournamentType tournamentType
    ) external onlyOwner {
        require(entryFee >= minTournamentFee, "Entry fee too low");
        require(maxPlayers >= 2, "Need at least 2 players");
        require(duration <= maxTournamentDuration, "Duration too long");
        
        _tournamentIds.increment();
        uint256 tournamentId = _tournamentIds.current();
        
        Tournament storage tournament = tournaments[tournamentId];
        tournament.id = tournamentId;
        tournament.name = name;
        tournament.entryFee = entryFee;
        tournament.maxPlayers = maxPlayers;
        tournament.startTime = block.timestamp;
        tournament.endTime = block.timestamp + duration;
        tournament.isActive = true;
        tournament.tournamentType = tournamentType;
        
        emit TournamentCreated(tournamentId, name, entryFee, maxPlayers);
    }
    
    /**
     * @dev Join a tournament
     */
    function joinTournament(uint256 tournamentId) external nonReentrant whenNotPaused {
        Tournament storage tournament = tournaments[tournamentId];
        require(tournament.isActive, "Tournament not active");
        require(tournament.currentPlayers < tournament.maxPlayers, "Tournament full");
        require(block.timestamp < tournament.endTime, "Tournament ended");
        require(!_isPlayerInTournament(tournamentId, msg.sender), "Already joined");
        
        // Transfer entry fee
        gameToken.transferFrom(msg.sender, address(this), tournament.entryFee);
        
        tournament.participants.push(msg.sender);
        tournament.currentPlayers++;
        tournament.prizePool += tournament.entryFee;
        
        emit TournamentJoined(tournamentId, msg.sender);
    }
    
    /**
     * @dev Finish tournament and distribute prizes
     */
    function finishTournament(
        uint256 tournamentId,
        address[] memory winners,
        uint256[] memory prizes
    ) external onlyOwner {
        Tournament storage tournament = tournaments[tournamentId];
        require(tournament.isActive, "Tournament not active");
        require(winners.length == prizes.length, "Arrays length mismatch");
        
        uint256 totalPrizes = 0;
        for (uint256 i = 0; i < prizes.length; i++) {
            totalPrizes += prizes[i];
        }
        require(totalPrizes <= tournament.prizePool, "Prizes exceed pool");
        
        // Distribute prizes
        for (uint256 i = 0; i < winners.length; i++) {
            gameToken.transfer(winners[i], prizes[i]);
            playerStats[winners[i]].totalWins++;
            playerStats[winners[i]].totalEarnings += prizes[i];
        }
        
        // Send remaining to treasury
        uint256 remaining = tournament.prizePool - totalPrizes;
        if (remaining > 0) {
            gameToken.transfer(treasuryWallet, remaining);
        }
        
        tournament.winners = winners;
        tournament.prizes = prizes;
        tournament.isActive = false;
        tournament.isFinished = true;
        
        emit TournamentFinished(tournamentId, winners, prizes);
    }
    
    // Game Management Functions
    
    /**
     * @dev Register a new game
     */
    function registerGame(
        string memory name,
        address developer,
        uint256 revenueShare
    ) external onlyOwner {
        require(revenueShare <= 100, "Invalid revenue share");
        
        _gameIds.increment();
        uint256 gameId = _gameIds.current();
        
        Game storage game = games[gameId];
        game.id = gameId;
        game.name = name;
        game.developer = developer;
        game.revenueShare = revenueShare;
        game.isActive = true;
        
        emit GameRegistered(gameId, name, developer);
    }
    
    /**
     * @dev Start a game session
     */
    function startGameSession(uint256 gameId) external nonReentrant whenNotPaused {
        require(games[gameId].isActive, "Game not active");
        
        _sessionIds.increment();
        uint256 sessionId = _sessionIds.current();
        
        GameSession storage session = gameSessions[sessionId];
        session.id = sessionId;
        session.gameId = gameId;
        session.player = msg.sender;
        session.startTime = block.timestamp;
        
        games[gameId].totalSessions++;
        games[gameId].playerSessions[msg.sender]++;
        playerStats[msg.sender].totalGamesPlayed++;
        
        emit GameSessionStarted(sessionId, gameId, msg.sender);
    }
    
    /**
     * @dev Finish game session and calculate rewards
     */
    function finishGameSession(
        uint256 sessionId,
        uint256 score,
        bytes32 sessionHash,
        bytes memory signature
    ) external nonReentrant {
        GameSession storage session = gameSessions[sessionId];
        require(session.player == msg.sender, "Not your session");
        require(session.endTime == 0, "Session already finished");
        require(!usedSessionHashes[sessionHash], "Session hash already used");
        
        // Validate session with authorized validator signature
        require(_validateSession(sessionId, score, sessionHash, signature), "Invalid session");
        
        session.endTime = block.timestamp;
        session.score = score;
        session.sessionHash = sessionHash;
        session.isValidated = true;
        usedSessionHashes[sessionHash] = true;
        
        // Calculate reward based on score and game difficulty
        uint256 reward = _calculateReward(session.gameId, score);
        session.reward = reward;
        
        // Update player stats
        games[session.gameId].playerScores[msg.sender] = score;
        playerStats[msg.sender].experience += score / 100;
        
        // Check for level up
        _checkLevelUp(msg.sender);
        
        // Check for achievements
        _checkAchievements(msg.sender);
        
        // Mint reward tokens
        if (reward > 0) {
            gameToken.mintGameReward(msg.sender, reward, "Game completion reward");
            playerStats[msg.sender].totalEarnings += reward;
            
            // Distribute revenue to developer
            uint256 developerShare = (reward * games[session.gameId].revenueShare) / 100;
            if (developerShare > 0) {
                gameToken.mintGameReward(games[session.gameId].developer, developerShare, "Developer revenue share");
                games[session.gameId].totalRevenue += developerShare;
                emit RevenueDistributed(session.gameId, games[session.gameId].developer, developerShare);
            }
        }
        
        emit GameSessionFinished(sessionId, score, reward);
    }
    
    // Achievement System
    
    /**
     * @dev Create a new achievement
     */
    function createAchievement(
        string memory name,
        string memory description,
        uint256 requiredValue,
        AchievementType achievementType,
        uint256 reward
    ) external onlyOwner {
        uint256 achievementId = achievements.length;
        
        Achievement storage achievement = achievements[achievementId];
        achievement.id = achievementId;
        achievement.name = name;
        achievement.description = description;
        achievement.requiredValue = requiredValue;
        achievement.achievementType = achievementType;
        achievement.reward = reward;
        achievement.isActive = true;
    }
    
    // Internal Functions
    
    function _isPlayerInTournament(uint256 tournamentId, address player) internal view returns (bool) {
        Tournament storage tournament = tournaments[tournamentId];
        for (uint256 i = 0; i < tournament.participants.length; i++) {
            if (tournament.participants[i] == player) {
                return true;
            }
        }
        return false;
    }
    
    function _calculateReward(uint256 gameId, uint256 score) internal view returns (uint256) {
        // Base reward calculation - can be customized per game
        uint256 baseReward = 10 * 10**18; // 10 tokens base
        uint256 scoreMultiplier = score / 1000; // 1 token per 1000 points
        return baseReward + (scoreMultiplier * 10**18);
    }
    
    function _validateSession(
        uint256 sessionId,
        uint256 score,
        bytes32 sessionHash,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(sessionId, score, sessionHash));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        
        address signer = _recoverSigner(ethSignedMessageHash, signature);
        return authorizedValidators[signer];
    }
    
    function _recoverSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "Invalid signature length");
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        return ecrecover(hash, v, r, s);
    }
    
    function _checkLevelUp(address player) internal {
        PlayerStats storage stats = playerStats[player];
        uint256 newLevel = stats.experience / 1000; // Level up every 1000 XP
        
        if (newLevel > stats.level) {
            stats.level = newLevel;
            gameToken.updatePlayerLevel(player, newLevel);
            emit PlayerLevelUp(player, newLevel);
        }
    }
    
    function _checkAchievements(address player) internal {
        PlayerStats storage stats = playerStats[player];
        
        // Check all achievements
        for (uint256 i = 0; i < achievements.length; i++) {
            if (!playerAchievements[player][i] && achievements[i].isActive) {
                bool unlocked = false;
                
                if (achievements[i].achievementType == AchievementType.GAMES_PLAYED) {
                    unlocked = stats.totalGamesPlayed >= achievements[i].requiredValue;
                } else if (achievements[i].achievementType == AchievementType.WINS) {
                    unlocked = stats.totalWins >= achievements[i].requiredValue;
                } else if (achievements[i].achievementType == AchievementType.EARNINGS) {
                    unlocked = stats.totalEarnings >= achievements[i].requiredValue;
                } else if (achievements[i].achievementType == AchievementType.LEVEL) {
                    unlocked = stats.level >= achievements[i].requiredValue;
                }
                
                if (unlocked) {
                    playerAchievements[player][i] = true;
                    stats.achievementIds.push(i);
                    
                    if (achievements[i].reward > 0) {
                        gameToken.mintGameReward(player, achievements[i].reward, "Achievement reward");
                        stats.totalEarnings += achievements[i].reward;
                    }
                    
                    emit AchievementUnlocked(player, i, achievements[i].reward);
                }
            }
        }
    }
    
    // Admin Functions
    
    function setAuthorizedValidator(address validator, bool authorized) external onlyOwner {
        authorizedValidators[validator] = authorized;
    }
    
    function setPlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee too high");
        platformFee = newFee;
    }
    
    function setTreasuryWallet(address newTreasury) external onlyOwner {
        treasuryWallet = newTreasury;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // View Functions
    
    function getTournamentParticipants(uint256 tournamentId) external view returns (address[] memory) {
        return tournaments[tournamentId].participants;
    }
    
    function getPlayerAchievements(address player) external view returns (uint256[] memory) {
        return playerStats[player].achievementIds;
    }
    
    function getGameStats(uint256 gameId) external view returns (
        string memory name,
        address developer,
        uint256 totalSessions,
        uint256 totalRevenue,
        bool isActive
    ) {
        Game storage game = games[gameId];
        return (game.name, game.developer, game.totalSessions, game.totalRevenue, game.isActive);
    }
}
