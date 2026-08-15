// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title StakingRewardsWCC
 * @dev WCC token staking pool with WCC reward distribution for BSC.
 * Features:
 * - WCC token deposits
 * - Separate reward token (WCC) for rewards
 * - No registration required
 * - Configurable deposit fee (default 0.3%)
 * - Configurable pool cap and per-wallet cap
 * - Configurable reward period
 * - No time restrictions on deposits/withdrawals
 * - User can claim rewards directly
 */
contract StakingRewardsWCC is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // WCC staking token address
    IERC20 public immutable wccToken;
    
    // Reward token address (e.g., WCC)
    IERC20 public rewardToken;
    
    // Reward period (configurable, default 4 hours = 14400 seconds)
    uint256 public rewardPeriod;

    // Deposit fee in basis points (default 30 = 0.3%)
    uint256 public depositFeeBps;
    
    // Maximum total staking amount for the pool (0 = no limit)
    uint256 public poolCap;
    
    // Maximum staking amount per wallet (0 = no limit)
    uint256 public walletCap;

    // Reward amount per period
    uint256 public rewardPerPeriod;

    // Reward start time
    uint256 public rewardStartTime;

    // Last reward update time
    uint256 public lastRewardUpdateTime;

    // Total staked amount
    uint256 public totalStaked;

    // Total claimed rewards across all users
    uint256 public totalClaimed;
    
    // Total fees collected
    uint256 public totalFeesCollected;

    // Accumulated reward per share
    uint256 public accRewardPerShare;

    // Precision factor (used in reward calculations)
    uint256 private constant PRECISION = 1e18;
    
    // Basis points denominator (100% = 10000)
    uint256 private constant BPS_DENOMINATOR = 10000;

    // User information
    struct UserInfo {
        uint256 amount;          // user's staked amount (after fees)
        uint256 rewardDebt;      // reward debt
        uint256 pendingRewards;  // pending rewards
        uint256 claimedRewards;  // cumulative rewards claimed by user
    }

    // User staking info
    mapping(address => UserInfo) public userInfo;

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 fee);
    event Withdraw(address indexed user, uint256 amount);
    event RewardPerPeriodUpdated(uint256 newRewardPerPeriod);
    event RewardPeriodUpdated(uint256 newRewardPeriod);
    event DepositFeeUpdated(uint256 newDepositFeeBps);
    event PoolCapUpdated(uint256 newPoolCap);
    event WalletCapUpdated(uint256 newWalletCap);
    event RewardStartTimeUpdated(uint256 newRewardStartTime);
    event RemainingRewardsWithdrawn(address indexed owner, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event FeesWithdrawn(address indexed owner, uint256 amount);

    /**
     * @dev Constructor
     * @param _wccToken WCC staking token address
     * @param _rewardToken Reward token address (WCC)
     * @param _rewardPerPeriod Reward amount per period
     * @param _rewardStartTime Reward start time (0 = start immediately at deployment)
     * @param _rewardPeriod Reward period in seconds (default 4 hours)
     * @param _depositFeeBps Deposit fee in basis points (30 = 0.3%)
     * @param _poolCap Maximum total staking amount (0 = no limit)
     * @param _walletCap Maximum staking amount per wallet (0 = no limit)
     */
    constructor(
        address _wccToken,
        address _rewardToken,
        uint256 _rewardPerPeriod,
        uint256 _rewardStartTime,
        uint256 _rewardPeriod,
        uint256 _depositFeeBps,
        uint256 _poolCap,
        uint256 _walletCap
    ) Ownable(msg.sender) {
        require(_wccToken != address(0), "Invalid WCC address");
        require(_rewardToken != address(0), "Invalid reward token address");
        require(_rewardPeriod > 0, "Reward period must be > 0");
        require(_depositFeeBps <= 1000, "Fee too high (max 10%)");

        wccToken = IERC20(_wccToken);
        rewardToken = IERC20(_rewardToken);
        rewardPerPeriod = _rewardPerPeriod;
        rewardPeriod = _rewardPeriod;
        depositFeeBps = _depositFeeBps;
        poolCap = _poolCap;
        walletCap = _walletCap;

        // If no start time specified, start immediately
        rewardStartTime = _rewardStartTime == 0 ? block.timestamp : _rewardStartTime;
        lastRewardUpdateTime = rewardStartTime;
    }

    /**
     * @dev Update the reward token address
     * @param _rewardToken New reward token address
     */
    function setRewardToken(address _rewardToken) external onlyOwner {
        require(_rewardToken != address(0), "Invalid reward token address");
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Update the reward start time
     * @param _rewardStartTime New reward start time (0 = start immediately, otherwise must be >= current time)
     */
    function setRewardStartTime(uint256 _rewardStartTime) external onlyOwner {
        updateRewards();
        uint256 newStartTime = _rewardStartTime == 0 ? block.timestamp : _rewardStartTime;
        require(newStartTime >= block.timestamp, "Start time cannot be in the past");
        rewardStartTime = newStartTime;
        emit RewardStartTimeUpdated(rewardStartTime);
    }

    /**
     * @dev Withdraw remaining reward tokens (only when paused)
     * Since staking token and reward token are both WCC, we need to exclude staked amount and fees
     */
    function withdrawRemainingRewards() external onlyOwner whenPaused {
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        // Exclude user staked amount and collected fees (both are WCC)
        uint256 reservedAmount = totalStaked + totalFeesCollected;
        uint256 withdrawable = rewardBalance > reservedAmount ? rewardBalance - reservedAmount : 0;
        require(withdrawable > 0, "No remaining rewards to withdraw");
        
        rewardToken.safeTransfer(msg.sender, withdrawable);
        emit RemainingRewardsWithdrawn(msg.sender, withdrawable);
    }

    /**
     * @dev Update the reward amount per period
     * @param _rewardPerPeriod New reward amount
     */
    function setRewardPerPeriod(uint256 _rewardPerPeriod) external onlyOwner {
        updateRewards();
        rewardPerPeriod = _rewardPerPeriod;
        emit RewardPerPeriodUpdated(_rewardPerPeriod);
    }

    /**
     * @dev Update the reward period
     * @param _rewardPeriod New reward period in seconds
     */
    function setRewardPeriod(uint256 _rewardPeriod) external onlyOwner {
        require(_rewardPeriod > 0, "Reward period must be > 0");
        updateRewards();
        rewardPeriod = _rewardPeriod;
        emit RewardPeriodUpdated(_rewardPeriod);
    }

    /**
     * @dev Update the deposit fee
     * @param _depositFeeBps New deposit fee in basis points
     */
    function setDepositFee(uint256 _depositFeeBps) external onlyOwner {
        require(_depositFeeBps <= 1000, "Fee too high (max 10%)");
        depositFeeBps = _depositFeeBps;
        emit DepositFeeUpdated(_depositFeeBps);
    }

    /**
     * @dev Update the pool cap
     * @param _poolCap New pool cap (0 = no limit)
     */
    function setPoolCap(uint256 _poolCap) external onlyOwner {
        poolCap = _poolCap;
        emit PoolCapUpdated(_poolCap);
    }

    /**
     * @dev Update the wallet cap
     * @param _walletCap New wallet cap (0 = no limit)
     */
    function setWalletCap(uint256 _walletCap) external onlyOwner {
        walletCap = _walletCap;
        emit WalletCapUpdated(_walletCap);
    }

    /**
     * @dev Update rewards (core logic)
     */
    function updateRewards() public {
        if (totalStaked == 0) {
            lastRewardUpdateTime = block.timestamp;
            return;
        }

        if (block.timestamp < rewardStartTime) {
            return;
        }

        uint256 effectiveLastUpdate = lastRewardUpdateTime < rewardStartTime 
            ? rewardStartTime 
            : lastRewardUpdateTime;

        if (block.timestamp <= effectiveLastUpdate) {
            return;
        }

        uint256 timeDiff = block.timestamp - effectiveLastUpdate;
        uint256 periodsElapsed = timeDiff / rewardPeriod;

        if (periodsElapsed > 0) {
            uint256 totalRewards = periodsElapsed * rewardPerPeriod;
            accRewardPerShare += (totalRewards * PRECISION) / totalStaked;
            lastRewardUpdateTime = effectiveLastUpdate + (periodsElapsed * rewardPeriod);
        }
        // Note: Do NOT update lastRewardUpdateTime when periodsElapsed == 0
        // This allows time to accumulate until a full period is reached
    }

    /**
     * @dev Calculate pending rewards for a user
     * @param user User address
     * @return Amount of pending rewards
     */
    function pendingReward(address user) public view returns (uint256) {
        UserInfo storage userdata = userInfo[user];

        if (userdata.amount == 0) {
            return userdata.pendingRewards;
        }

        uint256 _accRewardPerShare = accRewardPerShare;

        if (totalStaked > 0 && block.timestamp >= rewardStartTime) {
            uint256 effectiveLastUpdate = lastRewardUpdateTime < rewardStartTime 
                ? rewardStartTime 
                : lastRewardUpdateTime;
            
            if (block.timestamp > effectiveLastUpdate) {
                uint256 timeDiff = block.timestamp - effectiveLastUpdate;
                uint256 periodsElapsed = timeDiff / rewardPeriod;

                if (periodsElapsed > 0) {
                    uint256 totalRewards = periodsElapsed * rewardPerPeriod;
                    _accRewardPerShare += (totalRewards * PRECISION) / totalStaked;
                }
            }
        }

        uint256 accumulatedReward = (userdata.amount * _accRewardPerShare) / PRECISION;
        return userdata.pendingRewards + accumulatedReward - userdata.rewardDebt;
    }

    /**
     * @dev Deposit WCC tokens
     * @param amount Deposit amount
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        updateRewards();

        // Calculate fee
        uint256 fee = (amount * depositFeeBps) / BPS_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;
        totalFeesCollected += fee;

        // Check pool cap
        if (poolCap > 0) {
            require(totalStaked + amountAfterFee <= poolCap, "Pool cap exceeded");
        }

        UserInfo storage user = userInfo[msg.sender];

        // Check wallet cap
        if (walletCap > 0) {
            require(user.amount + amountAfterFee <= walletCap, "Wallet cap exceeded");
        }

        // Settle previous rewards if user already has stake
        if (user.amount > 0) {
            uint256 pending = (user.amount * accRewardPerShare) / PRECISION - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        // Transfer tokens in (including fee)
        wccToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update user info and total staked
        user.amount += amountAfterFee;
        totalStaked += amountAfterFee;

        // Update reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;

        emit Deposit(msg.sender, amountAfterFee, fee);
    }

    /**
     * @dev Withdraw staked WCC
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Insufficient balance");
        require(amount > 0, "Amount must be greater than 0");

        updateRewards();

        // Settle pending rewards
        uint256 pending = (user.amount * accRewardPerShare) / PRECISION - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        // Update user info and total staked
        user.amount -= amount;
        totalStaked -= amount;

        // Update reward debt
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;

        // Transfer tokens out
        wccToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Claim rewards for the caller
     * @return amount The amount of rewards claimed
     */
    function claimRewards() external nonReentrant returns (uint256) {
        updateRewards();
        UserInfo storage user = userInfo[msg.sender];
        
        uint256 pending = (user.amount * accRewardPerShare) / PRECISION - user.rewardDebt;
        uint256 totalReward = user.pendingRewards + pending;
        require(totalReward > 0, "No rewards to claim");

        user.pendingRewards = 0;
        user.rewardDebt = (user.amount * accRewardPerShare) / PRECISION;
        user.claimedRewards += totalReward;
        totalClaimed += totalReward;

        // Transfer reward tokens to user
        rewardToken.safeTransfer(msg.sender, totalReward);

        emit RewardsClaimed(msg.sender, totalReward);
        return totalReward;
    }

    /**
     * @dev Emergency withdraw (forfeit rewards)
     */
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;

        require(amount > 0, "No balance to withdraw");

        // Reset user info
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;

        totalStaked -= amount;

        // Transfer tokens out
        wccToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    /**
     * @dev Withdraw collected fees (owner only)
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "No fees to withdraw");
        
        totalFeesCollected = 0;
        
        wccToken.safeTransfer(msg.sender, amount);
        
        emit FeesWithdrawn(msg.sender, amount);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Get user information
     * @param user User address
     */
    function getUserInfo(address user) external view returns (
        uint256 amount,
        uint256 rewardDebt,
        uint256 pendingRewards,
        uint256 claimableRewards,
        uint256 claimedRewards
    ) {
        UserInfo storage userdata = userInfo[user];
        return (
            userdata.amount,
            userdata.rewardDebt,
            userdata.pendingRewards,
            pendingReward(user),
            userdata.claimedRewards
        );
    }

    /**
     * @dev Get current APY (Annual Percentage Yield)
     * @return apy The current APY in basis points (e.g., 1000 = 10.00%)
     */
    function getCurrentAPY() external view returns (uint256 apy) {
        if (totalStaked == 0) {
            return 0;
        }
        
        uint256 periodsPerYear = 365 days / rewardPeriod;
        uint256 annualRewards = rewardPerPeriod * periodsPerYear;
        apy = (annualRewards * 10000) / totalStaked;
        
        return apy;
    }

    /**
     * @dev Get contract state info
     */
    function getContractInfo() external view returns (
        uint256 rewardPerPeriodAmount,
        uint256 rewardPeriodSeconds,
        uint256 totalStakedAmount,
        uint256 totalClaimedAmount,
        uint256 totalFeesAmount,
        uint256 rewardStartTimestamp,
        uint256 lastRewardUpdateTimestamp,
        uint256 currentTime,
        uint256 poolCapAmount,
        uint256 walletCapAmount,
        uint256 depositFee
    ) {
        return (
            rewardPerPeriod,
            rewardPeriod,
            totalStaked,
            totalClaimed,
            totalFeesCollected,
            rewardStartTime,
            lastRewardUpdateTime,
            block.timestamp,
            poolCap,
            walletCap,
            depositFeeBps
        );
    }
}
