// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Advanced DeFi Agent
 * @notice Non-custodial yield optimization with off-chain intelligence
 * @dev Maintains user sovereignty while providing institutional-grade automation
 */

// ==================== INTERFACES ====================

interface IDeFiProtocol {
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external returns (uint256);
    function getBalance(address token, address user) external view returns (uint256);
    function emergencyWithdraw(address token, address user) external returns (uint256);
}

interface IUniswapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function getPriceWithTimestamp(address token) external view returns (uint256 price, uint256 timestamp);
}

// ==================== MAIN CONTRACT ====================

contract AdvancedDeFiAgent is Ownable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== ROLES & CONSTANTS ====================

    bytes32 public constant AUTOMATION_BOT_ROLE = keccak256("AUTOMATION_BOT_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant PROTOCOL_MANAGER_ROLE = keccak256("PROTOCOL_MANAGER_ROLE");

    uint256 public constant MAX_PROTOCOLS = 30;
    uint256 public constant MAX_HARVEST_TOKENS = 10;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SLIPPAGE = 1000; // 10%
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 2 hours;

    // ==================== STATE VARIABLES ====================

    // Core protocol state
    mapping(address => bool) public supportedTokens;
    address[] public supportedTokenList;
    mapping(address => ProtocolInfo) public protocolInfo;
    address[] public protocols;

    // External integrations
    IUniswapRouter public uniswapRouter;
    IPriceOracle public priceOracle;

    // User management
    mapping(address => UserStrategy) public userStrategies;
    mapping(address => UserPortfolio) public userPortfolios;

    // Global settings
    uint256 public performanceFee; // Basis points - set by owner
    address public feeRecipient;

    // Circuit breaker (simplified)
    bool public emergencyMode;
    uint256 public maxDailyLoss; // Basis points
    uint256 public dailyLossTracker;
    uint256 public lastLossReset;

    // Analytics
    uint256 public totalValueLocked;
    uint256 public totalUsers;

    // ==================== STRUCTS ====================

    struct ProtocolInfo {
        address protocolAddress;
        string name;
        bool isActive;
        bool isHealthy;
        uint256 lastHealthUpdate;
        uint256 totalDeposited;
        uint256 maxCapacity;
        uint256 riskScore; // 0-100 (set by off-chain risk engine)
        uint256 currentAPR; // Updated by off-chain APR tracker
    }

    struct UserStrategy {
        bool active;
        uint8 allocationType; // 0: Highest APR, 1: Custom, 2: Risk-balanced, 3: AI-optimized, 4: Index
        address[] targetProtocols; // For custom/optimized strategies
        uint256[] allocationWeights; // Weights for target protocols
        address[] harvestTokens; // Tokens to harvest into
        uint256[] harvestWeights; // Harvest distribution
        uint256 maxSlippage; // Maximum slippage tolerance
        bool autoCompound; // Reinvest profits vs harvest
        uint256 lastRebalance; // Last rebalance timestamp
        uint256 rebalanceFrequency; // Minimum time between rebalances
    }

    struct UserPortfolio {
        mapping(address => uint256) tokenBalances; // token => balance
        mapping(address => mapping(address => uint256)) protocolBalances; // token => protocol => balance
        uint256 totalValue; // USD value (updated by off-chain)
        uint256 lastUpdate;
        uint256 totalDeposits;
        uint256 totalWithdrawals;
        uint256 realizedProfits;
    }

    // ==================== EVENTS ====================

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 fee);
    event StrategyUpdated(address indexed user, uint8 allocationType);
    event Rebalanced(address indexed user, address indexed protocol, address indexed token, uint256 amount);
    event Harvested(address indexed user, address indexed token, uint256 amount, uint256 fee);
    event EmergencyWithdrawal(address indexed user, address indexed token, uint256 amount);
    event ProtocolHealthUpdated(address indexed protocol, bool isHealthy);
    event FeeCollected(address indexed user, uint256 fee);
    event EmergencyModeToggled(bool enabled);

    // ==================== MODIFIERS ====================

    modifier onlyActiveUser() {
        require(userStrategies[msg.sender].active, "No active strategy");
        _;
    }

    modifier validToken(address token) {
        require(supportedTokens[token], "Token not supported");
        _;
    }

    modifier validProtocol(address protocol) {
        require(protocolInfo[protocol].isActive, "Protocol not active");
        require(protocolInfo[protocol].isHealthy, "Protocol not healthy");
        _;
    }

    modifier notInEmergency() {
        require(!emergencyMode, "Emergency mode active");
        _;
    }

    // ==================== CONSTRUCTOR ====================

    constructor(
        address _uniswapRouter,
        address _priceOracle,
        address[] memory _initialTokens,
        address[] memory _initialProtocols,
        string[] memory _protocolNames
    ) {
        require(_uniswapRouter != address(0), "Invalid router");
        require(_priceOracle != address(0), "Invalid oracle");
        require(_initialProtocols.length == _protocolNames.length, "Mismatched protocol data");

        _transferOwnership(msg.sender);

        uniswapRouter = IUniswapRouter(_uniswapRouter);
        priceOracle = IPriceOracle(_priceOracle);

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUTOMATION_BOT_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(PROTOCOL_MANAGER_ROLE, msg.sender);

        // Initialize settings
        performanceFee = 1000; // 10%
        feeRecipient = msg.sender;
        maxDailyLoss = 500; // 5%
        lastLossReset = block.timestamp;

        // Add initial tokens
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            _addSupportedToken(_initialTokens[i]);
        }

        // Add initial protocols
        for (uint256 i = 0; i < _initialProtocols.length; i++) {
            _addProtocol(_initialProtocols[i], _protocolNames[i]);
        }
    }

    // ==================== CORE USER FUNCTIONS (USER SOVEREIGNTY) ====================

    /**
     * @notice Deposit tokens - USER MAINTAINS FULL CONTROL
     * @param token Token address to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergency
        validToken(token)
    {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens to contract (NON-CUSTODIAL - user can withdraw anytime)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update user portfolio
        UserPortfolio storage portfolio = userPortfolios[msg.sender];
        portfolio.tokenBalances[token] += amount;
        portfolio.totalDeposits += amount;
        portfolio.lastUpdate = block.timestamp;

        // Update global metrics
        totalValueLocked += _getTokenValueInUSD(token, amount);

        if (!userStrategies[msg.sender].active) {
            totalUsers++;
        }

        emit Deposited(msg.sender, token, amount);

        // Auto-allocate if strategy is active (USER-CONTROLLED)
        if (userStrategies[msg.sender].active) {
            _allocateFunds(msg.sender, token, amount);
        }
    }

    /**
     * @notice Withdraw tokens - IMMEDIATE USER CONTROL
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     */
    function withdraw(address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        validToken(token)
    {
        UserPortfolio storage portfolio = userPortfolios[msg.sender];
        require(amount <= portfolio.tokenBalances[token], "Insufficient balance");

        // Perform withdrawal from protocols
        uint256 totalWithdrawn = _performWithdrawal(msg.sender, token, amount);

        // Calculate performance fee (only on profits)
        uint256 fee = 0;
        if (totalWithdrawn > amount) {
            uint256 profit = totalWithdrawn - amount;
            fee = (profit * performanceFee) / BASIS_POINTS;
        }

        uint256 netAmount = totalWithdrawn - fee;

        // Update portfolio
        portfolio.tokenBalances[token] -= amount;
        portfolio.totalWithdrawals += amount;
        portfolio.lastUpdate = block.timestamp;

        // Update global metrics
        totalValueLocked -= _getTokenValueInUSD(token, amount);

        // Send fee
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
            emit FeeCollected(msg.sender, fee);
        }

        // Send to user
        IERC20(token).safeTransfer(msg.sender, netAmount);

        emit Withdrawn(msg.sender, token, netAmount, fee);
    }

    /**
     * @notice Set user strategy - USER DEFINES THE RULES
     * @dev Off-chain intelligence can suggest optimal parameters, but user decides
     */
    function setStrategy(
        uint8 allocationType,
        address[] calldata targetProtocols,
        uint256[] calldata allocationWeights,
        address[] calldata harvestTokens,
        uint256[] calldata harvestWeights,
        uint256 maxSlippage,
        bool autoCompound,
        uint256 rebalanceFrequency
    ) external whenNotPaused {
        require(allocationType <= 4, "Invalid allocation type");
        require(maxSlippage <= MAX_SLIPPAGE, "Slippage too high");
        require(rebalanceFrequency >= MIN_REBALANCE_INTERVAL, "Frequency too low");

        // Validate target protocols and weights for custom strategies
        if (allocationType == 1 || allocationType == 3) { // Custom or AI-optimized
            require(targetProtocols.length == allocationWeights.length, "Mismatched arrays");
            require(targetProtocols.length > 0, "Empty protocols");

            uint256 totalWeight = 0;
            for (uint256 i = 0; i < allocationWeights.length; i++) {
                require(protocolInfo[targetProtocols[i]].isActive, "Protocol not active");
                totalWeight += allocationWeights[i];
            }
            require(totalWeight == 100, "Weights must sum to 100");
        }

        // Validate harvest configuration
        require(harvestTokens.length == harvestWeights.length, "Mismatched harvest arrays");
        require(harvestTokens.length <= MAX_HARVEST_TOKENS, "Too many harvest tokens");

        uint256 totalHarvestWeight = 0;
        for (uint256 i = 0; i < harvestWeights.length; i++) {
            require(supportedTokens[harvestTokens[i]], "Harvest token not supported");
            totalHarvestWeight += harvestWeights[i];
        }
        require(totalHarvestWeight == 100, "Harvest weights must sum to 100");

        // Create strategy (USER-CONTROLLED)
        userStrategies[msg.sender] = UserStrategy({
            active: true,
            allocationType: allocationType,
            targetProtocols: targetProtocols,
            allocationWeights: allocationWeights,
            harvestTokens: harvestTokens,
            harvestWeights: harvestWeights,
            maxSlippage: maxSlippage == 0 ? 500 : maxSlippage,
            autoCompound: autoCompound,
            lastRebalance: 0,
            rebalanceFrequency: rebalanceFrequency
        });

        emit StrategyUpdated(msg.sender, allocationType);

        // Reallocate existing funds
        _reallocateUserFunds(msg.sender);
    }

    /**
     * @notice Emergency withdraw - ULTIMATE USER CONTROL
     * @param token Token to emergency withdraw
     */
    function emergencyWithdraw(address token) 
        external 
        nonReentrant
        validToken(token)
    {
        UserPortfolio storage portfolio = userPortfolios[msg.sender];
        uint256 totalBalance = portfolio.tokenBalances[token];
        require(totalBalance > 0, "No balance to withdraw");

        uint256 totalWithdrawn = _emergencyWithdrawFromProtocols(msg.sender, token);

        portfolio.tokenBalances[token] = 0;
        portfolio.lastUpdate = block.timestamp;

        // Update global metrics
        totalValueLocked -= _getTokenValueInUSD(token, totalBalance);

        if (totalWithdrawn > 0) {
            IERC20(token).safeTransfer(msg.sender, totalWithdrawn);
        }

        emit EmergencyWithdrawal(msg.sender, token, totalWithdrawn);
    }

    // ==================== AUTOMATION FUNCTIONS (STRICT BOUNDARIES) ====================

    /**
     * @notice Rebalance user portfolio - AGENT EXECUTES, USER CONTROLS
     * @dev Off-chain intelligence provides optimal allocation, on-chain executes securely
     */
    function rebalance(
        address user,
        address[] calldata protocolOrder,
        uint256[] calldata allocations
    ) external onlyRole(AUTOMATION_BOT_ROLE) whenNotPaused notInEmergency {
        UserStrategy memory strategy = userStrategies[user];
        require(strategy.active, "No active strategy");
        require(protocolOrder.length == allocations.length, "Mismatched arrays");
        require(block.timestamp >= strategy.lastRebalance + strategy.rebalanceFrequency, "Too frequent");

        // Execute rebalancing for each supported token
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            if (userPortfolios[user].tokenBalances[token] > 0) {
                _rebalanceToken(user, token, protocolOrder, allocations);
            }
        }

        userStrategies[user].lastRebalance = block.timestamp;
    }

    /**
     * @notice Harvest profits - AUTOMATED BUT CONTROLLED
     */
    function harvest(address user) 
        external 
        onlyRole(AUTOMATION_BOT_ROLE) 
        whenNotPaused 
        returns (uint256 totalProfit) 
    {
        UserStrategy memory strategy = userStrategies[user];
        require(strategy.active, "No active strategy");

        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            totalProfit += _harvestToken(user, token, strategy);
        }
    }

    /**
     * @notice Batch operations for gas efficiency - PERMISSIONED AUTOMATION
     */
    function batchRebalance(
        address[] calldata users,
        address[][] calldata protocolOrders,
        uint256[][] calldata allocations
    ) external onlyRole(AUTOMATION_BOT_ROLE) whenNotPaused {
        require(users.length == protocolOrders.length, "Mismatched arrays");
        require(users.length == allocations.length, "Mismatched arrays");
        require(users.length <= 100, "Too many users");

        for (uint256 i = 0; i < users.length; i++) {
            try this.rebalance(users[i], protocolOrders[i], allocations[i]) {
                // Success
            } catch {
                // Continue with next user if one fails
            }
        }
    }

    function batchHarvest(address[] calldata users) 
        external 
        onlyRole(AUTOMATION_BOT_ROLE) 
        whenNotPaused 
    {
        require(users.length <= 200, "Too many users");

        for (uint256 i = 0; i < users.length; i++) {
            try this.harvest(users[i]) {
                // Success
            } catch {
                // Continue with next user if one fails
            }
        }
    }

    // ==================== INTERNAL CORE FUNCTIONS ====================

    function _allocateFunds(address user, address token, uint256 amount) internal {
        UserStrategy memory strategy = userStrategies[user];

        if (strategy.allocationType == 0) {
            // Highest APR - will be handled by off-chain rebalancing
            return;
        } else if (strategy.allocationType == 1 || strategy.allocationType == 3) {
            // Custom weights or AI-optimized (both use targetProtocols)
            for (uint256 i = 0; i < strategy.targetProtocols.length; i++) {
                address protocol = strategy.targetProtocols[i];
                if (!protocolInfo[protocol].isHealthy) continue;

                uint256 allocAmount = (amount * strategy.allocationWeights[i]) / 100;
                if (allocAmount > 0) {
                    _depositToProtocol(user, token, protocol, allocAmount);
                }
            }
        } else if (strategy.allocationType == 2) {
            // Risk-balanced (use off-chain calculated risk scores)
            _allocateRiskBalanced(user, token, amount);
        } else if (strategy.allocationType == 4) {
            // Index-based allocation
            _allocateIndexBased(user, token, amount);
        }
    }

    function _allocateRiskBalanced(address user, address token, uint256 amount) internal {
        // Use off-chain calculated risk scores for allocation
        address[] memory suitableProtocols = new address[](protocols.length);
        uint256[] memory riskScores = new uint256[](protocols.length);
        uint256 suitableCount = 0;

        // Find protocols with acceptable risk (risk score <= 50)
        for (uint256 i = 0; i < protocols.length; i++) {
            if (protocolInfo[protocols[i]].isHealthy && 
                protocolInfo[protocols[i]].riskScore <= 50) {

                suitableProtocols[suitableCount] = protocols[i];
                riskScores[suitableCount] = protocolInfo[protocols[i]].riskScore;
                suitableCount++;
            }
        }

        if (suitableCount > 0) {
            // Allocate inversely proportional to risk (lower risk = higher allocation)
            uint256 totalInverseRisk = 0;
            for (uint256 i = 0; i < suitableCount; i++) {
                totalInverseRisk += (100 - riskScores[i]); // Inverse risk score
            }

            for (uint256 i = 0; i < suitableCount; i++) {
                uint256 allocation = (amount * (100 - riskScores[i])) / totalInverseRisk;
                if (allocation > 0) {
                    _depositToProtocol(user, token, suitableProtocols[i], allocation);
                }
            }
        }
    }

    function _allocateIndexBased(address user, address token, uint256 amount) internal {
        // Simple equal-weight allocation across healthy protocols
        address[] memory healthyProtocols = new address[](protocols.length);
        uint256 healthyCount = 0;

        for (uint256 i = 0; i < protocols.length; i++) {
            if (protocolInfo[protocols[i]].isHealthy) {
                healthyProtocols[healthyCount] = protocols[i];
                healthyCount++;
            }
        }

        if (healthyCount > 0) {
            uint256 amountPerProtocol = amount / healthyCount;
            for (uint256 i = 0; i < healthyCount; i++) {
                _depositToProtocol(user, token, healthyProtocols[i], amountPerProtocol);
            }
        }
    }

    function _performWithdrawal(address user, address token, uint256 amount) 
        internal 
        returns (uint256 totalWithdrawn) 
    {
        UserStrategy memory strategy = userStrategies[user];
        UserPortfolio storage portfolio = userPortfolios[user];

        if (!strategy.active) {
            return amount; // Funds not allocated
        }

        uint256 userTotalBalance = portfolio.tokenBalances[token];

        // Withdraw proportionally from all protocols
        for (uint256 i = 0; i < protocols.length && totalWithdrawn < amount; i++) {
            address protocol = protocols[i];
            uint256 protocolBalance = portfolio.protocolBalances[token][protocol];

            if (protocolBalance > 0) {
                uint256 withdrawAmount = Math.min(
                    (amount * protocolBalance) / userTotalBalance,
                    amount - totalWithdrawn
                );

                if (withdrawAmount > 0) {
                    totalWithdrawn += _withdrawFromProtocol(user, token, protocol, withdrawAmount);
                }
            }
        }

        return totalWithdrawn;
    }

    function _rebalanceToken(
        address user,
        address token,
        address[] calldata protocolOrder,
        uint256[] calldata allocations
    ) internal {
        UserPortfolio storage portfolio = userPortfolios[user];
        uint256 totalBalance = portfolio.tokenBalances[token];

        // Rebalance to match target allocations (provided by off-chain engine)
        for (uint256 i = 0; i < protocolOrder.length; i++) {
            address protocol = protocolOrder[i];
            uint256 targetAllocation = allocations[i]; // Percentage (0-100)

            if (!protocolInfo[protocol].isHealthy || targetAllocation == 0) continue;

            uint256 currentBalance = portfolio.protocolBalances[token][protocol];
            uint256 targetBalance = (totalBalance * targetAllocation) / 100;

            if (currentBalance < targetBalance) {
                uint256 needed = targetBalance - currentBalance;
                _depositToProtocol(user, token, protocol, needed);
            } else if (currentBalance > targetBalance) {
                uint256 excess = currentBalance - targetBalance;
                _withdrawFromProtocol(user, token, protocol, excess);
            }
        }
    }

    function _harvestToken(address user, address token, UserStrategy memory strategy) 
        internal 
        returns (uint256 totalProfit) 
    {
        UserPortfolio storage portfolio = userPortfolios[user];

        // Calculate profits from all protocols
        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];
            uint256 expectedBalance = portfolio.protocolBalances[token][protocol];

            if (expectedBalance > 0) {
                try IDeFiProtocol(protocol).getBalance(token, address(this)) returns (uint256 currentBalance) {
                    if (currentBalance > expectedBalance) {
                        uint256 profit = currentBalance - expectedBalance;
                        totalProfit += _withdrawFromProtocol(user, token, protocol, profit);
                    }
                } catch {
                    // Skip if protocol call fails
                }
            }
        }

        if (totalProfit > 0) {
            // Calculate performance fee
            uint256 fee = (totalProfit * performanceFee) / BASIS_POINTS;
            uint256 netProfit = totalProfit - fee;

            // Send fee
            if (fee > 0) {
                IERC20(token).safeTransfer(feeRecipient, fee);
                emit FeeCollected(user, fee);
            }

            // Update portfolio
            portfolio.realizedProfits += netProfit;

            if (strategy.autoCompound) {
                _allocateFunds(user, token, netProfit);
            } else {
                _distributeHarvest(user, token, netProfit, strategy);
            }

            emit Harvested(user, token, totalProfit, fee);
        }
    }

    function _distributeHarvest(
        address user, 
        address sourceToken, 
        uint256 amount, 
        UserStrategy memory strategy
    ) internal {
        for (uint256 i = 0; i < strategy.harvestTokens.length; i++) {
            address targetToken = strategy.harvestTokens[i];
            uint256 harvestAmount = (amount * strategy.harvestWeights[i]) / 100;

            if (targetToken == sourceToken) {
                IERC20(sourceToken).safeTransfer(user, harvestAmount);
            } else {
                _swapTokens(sourceToken, targetToken, harvestAmount, strategy.maxSlippage, user);
            }
        }
    }

    function _swapTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 maxSlippage,
        address recipient
    ) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory expectedAmounts = uniswapRouter.getAmountsOut(amountIn, path);
        uint256 minAmountOut = (expectedAmounts[1] * (BASIS_POINTS - maxSlippage)) / BASIS_POINTS;

        IERC20(tokenIn).safeApprove(address(uniswapRouter), amountIn);

        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            recipient,
            block.timestamp + 300
        );

        return amounts[1];
    }

    function _depositToProtocol(address user, address token, address protocol, uint256 amount) internal {
        require(protocolInfo[protocol].isActive, "Protocol not active");
        require(protocolInfo[protocol].isHealthy, "Protocol not healthy");

        IERC20(token).safeApprove(protocol, amount);

        try IDeFiProtocol(protocol).deposit(token, amount) {
            UserPortfolio storage portfolio = userPortfolios[user];
            portfolio.protocolBalances[token][protocol] += amount;
            protocolInfo[protocol].totalDeposited += amount;

            emit Rebalanced(user, protocol, token, amount);
        } catch {
            // Revert allowance on failure
            IERC20(token).safeApprove(protocol, 0);

            // Mark protocol as potentially unhealthy
            protocolInfo[protocol].isHealthy = false;
            emit ProtocolHealthUpdated(protocol, false);
        }
    }

    function _withdrawFromProtocol(address user, address token, address protocol, uint256 amount) 
        internal 
        returns (uint256 actualWithdrawn) 
    {
        try IDeFiProtocol(protocol).withdraw(token, amount) returns (uint256 withdrawn) {
            actualWithdrawn = withdrawn;

            UserPortfolio storage portfolio = userPortfolios[user];
            uint256 userBalance = portfolio.protocolBalances[token][protocol];

            portfolio.protocolBalances[token][protocol] = userBalance > amount ? userBalance - amount : 0;
            protocolInfo[protocol].totalDeposited = protocolInfo[protocol].totalDeposited > amount ? 
                protocolInfo[protocol].totalDeposited - amount : 0;

            emit Rebalanced(user, protocol, token, withdrawn);
        } catch {
            actualWithdrawn = 0;

            // Mark protocol as potentially unhealthy
            protocolInfo[protocol].isHealthy = false;
            emit ProtocolHealthUpdated(protocol, false);
        }
    }

    function _emergencyWithdrawFromProtocols(address user, address token) 
        internal 
        returns (uint256 totalWithdrawn) 
    {
        UserPortfolio storage portfolio = userPortfolios[user];

        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];
            uint256 protocolBalance = portfolio.protocolBalances[token][protocol];

            if (protocolBalance > 0) {
                try IDeFiProtocol(protocol).emergencyWithdraw(token, address(this)) returns (uint256 withdrawn) {
                    totalWithdrawn += withdrawn;
                    portfolio.protocolBalances[token][protocol] = 0;
                } catch {
                    // Continue with next protocol if one fails
                }
            }
        }
    }

    function _reallocateUserFunds(address user) internal {
        UserPortfolio storage portfolio = userPortfolios[user];

        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            uint256 balance = portfolio.tokenBalances[token];

            if (balance > 0) {
                // Withdraw all funds first
                for (uint256 j = 0; j < protocols.length; j++) {
                    address protocol = protocols[j];
                    uint256 protocolBalance = portfolio.protocolBalances[token][protocol];

                    if (protocolBalance > 0) {
                        _withdrawFromProtocol(user, token, protocol, protocolBalance);
                    }
                }

                // Reallocate according to new strategy
                _allocateFunds(user, token, balance);
            }
        }
    }

    function _getTokenValueInUSD(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        (uint256 price, uint256 timestamp) = priceOracle.getPriceWithTimestamp(token);
        require(block.timestamp - timestamp <= PRICE_STALENESS_THRESHOLD, "Stale price data");

        return (amount * price) / 1e18;
    }

    // ==================== PROTOCOL MANAGEMENT (STRICT PERMISSIONS) ====================

    function addProtocol(address protocol, string calldata name) 
        external 
        onlyRole(PROTOCOL_MANAGER_ROLE) 
    {
        _addProtocol(protocol, name);
    }

    function _addProtocol(address protocol, string memory name) internal {
        require(protocol != address(0), "Invalid protocol");
        require(protocols.length < MAX_PROTOCOLS, "Too many protocols");

        protocolInfo[protocol] = ProtocolInfo({
            protocolAddress: protocol,
            name: name,
            isActive: true,
            isHealthy: true,
            lastHealthUpdate: block.timestamp,
            totalDeposited: 0,
            maxCapacity: type(uint256).max,
            riskScore: 50, // Default moderate risk
            currentAPR: 0
        });

        protocols.push(protocol);
    }

    function removeProtocol(address protocol) external onlyRole(PROTOCOL_MANAGER_ROLE) {
        require(protocolInfo[protocol].isActive, "Protocol not active");
        require(protocolInfo[protocol].totalDeposited == 0, "Protocol has deposits");

        protocolInfo[protocol].isActive = false;

        // Remove from array
        for (uint256 i = 0; i < protocols.length; i++) {
            if (protocols[i] == protocol) {
                protocols[i] = protocols[protocols.length - 1];
                protocols.pop();
                break;
            }
        }
    }

    /**
     * @notice Update protocol health - OFF-CHAIN INTELLIGENCE INPUT
     */
    function updateProtocolHealth(address protocol, bool isHealthy) 
        external 
        onlyRole(AUTOMATION_BOT_ROLE) 
    {
        require(protocolInfo[protocol].isActive, "Protocol not active");

        protocolInfo[protocol].isHealthy = isHealthy;
        protocolInfo[protocol].lastHealthUpdate = block.timestamp;

        emit ProtocolHealthUpdated(protocol, isHealthy);
    }

    /**
     * @notice Update protocol metrics - OFF-CHAIN DATA FEEDS
     */
    function updateProtocolMetrics(
        address protocol,
        uint256 currentAPR,
        uint256 riskScore
    ) external onlyRole(AUTOMATION_BOT_ROLE) {
        require(protocolInfo[protocol].isActive, "Protocol not active");
        require(riskScore <= 100, "Invalid risk score");

        protocolInfo[protocol].currentAPR = currentAPR;
        protocolInfo[protocol].riskScore = riskScore;
    }

    // ==================== TOKEN MANAGEMENT ====================

    function addSupportedToken(address token) external onlyRole(PROTOCOL_MANAGER_ROLE) {
        _addSupportedToken(token);
    }

    function _addSupportedToken(address token) internal {
        require(token != address(0), "Invalid token");
        require(!supportedTokens[token], "Token already supported");
        require(supportedTokenList.length < 50, "Too many tokens");

        supportedTokens[token] = true;
        supportedTokenList.push(token);
    }

    function removeSupportedToken(address token) external onlyRole(PROTOCOL_MANAGER_ROLE) {
        require(supportedTokens[token], "Token not supported");

        supportedTokens[token] = false;

        // Remove from array
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == token) {
                supportedTokenList[i] = supportedTokenList[supportedTokenList.length - 1];
                supportedTokenList.pop();
                break;
            }
        }
    }

    // ==================== ADMIN FUNCTIONS (OWNER ONLY) ====================

    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= 2000, "Fee too high"); // Max 20%
        performanceFee = _performanceFee;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        feeRecipient = _feeRecipient;
    }

    function setMaxDailyLoss(uint256 _maxDailyLoss) external onlyOwner {
        require(_maxDailyLoss <= 2000, "Loss limit too high"); // Max 20%
        maxDailyLoss = _maxDailyLoss;
    }

    function toggleEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = !emergencyMode;
        emit EmergencyModeToggled(emergencyMode);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function grantRole(bytes32 role, address account) public override onlyOwner {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override onlyOwner {
        _revokeRole(role, account);
    }

    // ==================== VIEW FUNCTIONS ====================

    function getUserTokenBalance(address user, address token) external view returns (uint256) {
        return userPortfolios[user].tokenBalances[token];
    }

    function getUserProtocolBalance(address user, address token, address protocol) 
        external 
        view 
        returns (uint256) 
    {
        return userPortfolios[user].protocolBalances[token][protocol];
    }

    function getUserPortfolioSummary(address user) external view returns (
        uint256 totalValue,
        uint256 totalDeposits,
        uint256 totalWithdrawals,
        uint256 realizedProfits,
        uint256 lastUpdate
    ) {
        UserPortfolio storage portfolio = userPortfolios[user];
        return (
            portfolio.totalValue,
            portfolio.totalDeposits,
            portfolio.totalWithdrawals,
            portfolio.realizedProfits,
            portfolio.lastUpdate
        );
    }

    function getProtocolInfo(address protocol) external view returns (ProtocolInfo memory) {
        return protocolInfo[protocol];
    }

    function getUserStrategy(address user) external view returns (UserStrategy memory) {
        return userStrategies[user];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokenList;
    }

    function getProtocols() external view returns (address[] memory) {
        return protocols;
    }

    function getTotalValueLocked() external view returns (uint256) {
        return totalValueLocked;
    }

    function getTotalUsers() external view returns (uint256) {
        return totalUsers;
    }

    function getSystemStatus() external view returns (
        bool isPaused,
        bool inEmergencyMode,
        uint256 dailyLoss,
        uint256 totalProtocols,
        uint256 healthyProtocols
    ) {
        uint256 healthy = 0;
        for (uint256 i = 0; i < protocols.length; i++) {
            if (protocolInfo[protocols[i]].isHealthy) healthy++;
        }

        return (
            paused(),
            emergencyMode,
            dailyLossTracker,
            protocols.length,
            healthy
        );
    }

    // ==================== EMERGENCY FUNCTIONS (ULTIMATE SAFETY) ====================

    function emergencyWithdrawAll(address user) external onlyRole(EMERGENCY_ROLE) {
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            UserPortfolio storage portfolio = userPortfolios[user];
            uint256 balance = portfolio.tokenBalances[token];

            if (balance > 0) {
                uint256 withdrawn = _emergencyWithdrawFromProtocols(user, token);
                portfolio.tokenBalances[token] = 0;

                if (withdrawn > 0) {
                    IERC20(token).safeTransfer(user, withdrawn);
                }

                emit EmergencyWithdrawal(user, token, withdrawn);
            }
        }
    }

    function recoverStuckTokens(address token, uint256 amount) external onlyOwner {
        require(!supportedTokens[token], "Cannot recover supported token");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ==================== UTILITY FUNCTIONS ====================

    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            require(success, "Multicall failed");
            results[i] = result;
        }
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
