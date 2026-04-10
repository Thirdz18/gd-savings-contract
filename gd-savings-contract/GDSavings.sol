// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title GDSavings
 * @notice G$ time-locked savings contract with optional sponsor rewards.
 *
 * Durations (days): 1, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365
 * Limits: min 1,000 G$  |  max 1,000,000 G$
 * Bonus:  users who lock >= 100,000 G$ for >= 150 days earn an extra 1,000 G$
 *         (paid from the reward pool — only if funded by sponsors)
 *
 * Key design decisions:
 *   - Only the depositor can withdraw their own funds.
 *   - Funds are LOCKED until the unlock timestamp — no early exit.
 *   - Owner (SAVING_KEY) manages the reward pool but can NEVER touch user deposits.
 *   - Re-entrancy protected.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library Address {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }
    function functionCall(address target, bytes memory data, string memory errorMessage) internal returns (bytes memory) {
        require(isContract(target), "Address: call to non-contract");
        (bool success, bytes memory returndata) = target.call(data);
        if (success) {
            return returndata;
        } else {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        _transferOwnership(initialOwner);
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function owner() public view virtual returns (address) { return _owner; }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() { _status = _NOT_ENTERED; }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

abstract contract Pausable is Context {
    bool private _paused;
    event Paused(address account);
    event Unpaused(address account);

    constructor() { _paused = false; }

    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    function paused() public view returns (bool) { return _paused; }
    function _pause() internal { _paused = true; emit Paused(_msgSender()); }
    function _unpause() internal { _paused = false; emit Unpaused(_msgSender()); }
}

contract GDSavings is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable gd;

    // ── Constants ──────────────────────────────────────────────────────────────
    uint256 public constant MIN_DEPOSIT    = 1_000  * 1e18;
    uint256 public constant MAX_DEPOSIT    = 1_000_000 * 1e18;
    uint256 public constant BONUS_AMOUNT   = 1_000  * 1e18;  // 1,000 G$ bonus
    uint256 public constant BONUS_MIN_DEP  = 100_000 * 1e18; // qualify if deposit >= 100k G$
    uint256 public constant BONUS_MIN_DAYS = 150;             // and lock >= 150 days

    // Valid lock durations in days
    uint16[13] private VALID_DURATIONS = [1, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365];

    // ── State ──────────────────────────────────────────────────────────────────
    uint256 public depositIdCounter;
    uint256 public rewardPool;          // sponsor-funded reward pool (tracked separately)

    struct Deposit {
        address owner;
        uint256 amount;
        uint256 lockDays;
        uint256 depositedAt;
        uint256 unlocksAt;
        bool    withdrawn;
        bool    bonusClaimed;
    }

    mapping(uint256 => Deposit) public deposits;
    mapping(address => uint256[]) public userDepositIds;

    // ── Events ────────────────────────────────────────────────────────────────
    event Saved(address indexed user, uint256 indexed depositId, uint256 amount, uint256 lockDays, uint256 unlocksAt);
    event Withdrawn(address indexed user, uint256 indexed depositId, uint256 amount, uint256 timestamp);
    event BonusPaid(address indexed user, uint256 indexed depositId, uint256 bonus, uint256 timestamp);
    event RewardPoolFunded(address indexed sponsor, uint256 amount, uint256 timestamp);
    event RewardPoolWithdrawn(address indexed owner, uint256 amount, uint256 timestamp);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);

    constructor(address _gd) Ownable(msg.sender) {
        require(_gd != address(0), "Invalid token");
        gd = IERC20(_gd);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _isValidDuration(uint256 days_) internal view returns (bool) {
        for (uint16 i = 0; i < 13; i++) {
            if (VALID_DURATIONS[i] == days_) return true;
        }
        return false;
    }

    // ── User: Deposit (Save) ──────────────────────────────────────────────────

    /**
     * @notice Lock G$ tokens for a chosen duration.
     * @param amount   Amount in wei (18 decimals). Must be 1,000–1,000,000 G$.
     * @param lockDays One of: 1, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365
     */
    function depositSavings(uint256 amount, uint256 lockDays) external nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "Below minimum (1,000 G$)");
        require(amount <= MAX_DEPOSIT, "Above maximum (1,000,000 G$)");
        require(_isValidDuration(lockDays), "Invalid lock duration");

        gd.safeTransferFrom(msg.sender, address(this), amount);

        uint256 id = ++depositIdCounter;
        uint256 unlocksAt = block.timestamp + (lockDays * 1 days);

        deposits[id] = Deposit({
            owner:        msg.sender,
            amount:       amount,
            lockDays:     lockDays,
            depositedAt:  block.timestamp,
            unlocksAt:    unlocksAt,
            withdrawn:    false,
            bonusClaimed: false
        });

        userDepositIds[msg.sender].push(id);

        emit Saved(msg.sender, id, amount, lockDays, unlocksAt);
    }

    // ── User: Withdraw ────────────────────────────────────────────────────────

    /**
     * @notice Withdraw a matured deposit. Only the depositor can call this.
     *         If eligible for the bonus and the reward pool has enough funds,
     *         the 1,000 G$ bonus is automatically paid out with the principal.
     */
    function withdraw(uint256 depositId) external nonReentrant whenNotPaused {
        Deposit storage dep = deposits[depositId];

        require(dep.owner == msg.sender, "Not your deposit");
        require(!dep.withdrawn, "Already withdrawn");
        require(block.timestamp >= dep.unlocksAt, "Still locked");

        dep.withdrawn = true;

        uint256 payout = dep.amount;
        bool bonusPaid = false;

        // Check bonus eligibility
        if (!dep.bonusClaimed
            && dep.amount >= BONUS_MIN_DEP
            && dep.lockDays >= BONUS_MIN_DAYS
            && rewardPool >= BONUS_AMOUNT)
        {
            dep.bonusClaimed = true;
            rewardPool -= BONUS_AMOUNT;
            payout += BONUS_AMOUNT;
            bonusPaid = true;
        }

        gd.safeTransfer(msg.sender, payout);

        emit Withdrawn(msg.sender, depositId, dep.amount, block.timestamp);
        if (bonusPaid) {
            emit BonusPaid(msg.sender, depositId, BONUS_AMOUNT, block.timestamp);
        }
    }

    // ── Sponsor: Fund Reward Pool ──────────────────────────────────────────────

    /**
     * @notice Anyone (sponsors) can add G$ to the reward pool.
     *         These funds are ONLY used for bonuses — never mixed with user deposits.
     */
    function fundRewardPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        gd.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        emit RewardPoolFunded(msg.sender, amount, block.timestamp);
    }

    // ── Owner: Manage Reward Pool Only ────────────────────────────────────────

    /**
     * @notice Owner can withdraw from reward pool ONLY (never from user deposits).
     */
    function withdrawRewardPool(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(rewardPool >= amount, "Insufficient reward pool");
        rewardPool -= amount;
        gd.safeTransfer(owner(), amount);
        emit RewardPoolWithdrawn(owner(), amount, block.timestamp);
    }

    function pause() external onlyOwner { _pause(); emit ContractPaused(msg.sender); }
    function unpause() external onlyOwner { _unpause(); emit ContractUnpaused(msg.sender); }

    // ── View Functions ────────────────────────────────────────────────────────

    function getUserDepositIds(address user) external view returns (uint256[] memory) {
        return userDepositIds[user];
    }

    function getDeposit(uint256 depositId) external view returns (
        address owner_,
        uint256 amount,
        uint256 lockDays,
        uint256 depositedAt,
        uint256 unlocksAt,
        bool withdrawn,
        bool bonusClaimed,
        bool isUnlocked,
        bool bonusEligible
    ) {
        Deposit storage d = deposits[depositId];
        return (
            d.owner,
            d.amount,
            d.lockDays,
            d.depositedAt,
            d.unlocksAt,
            d.withdrawn,
            d.bonusClaimed,
            block.timestamp >= d.unlocksAt,
            d.amount >= BONUS_MIN_DEP && d.lockDays >= BONUS_MIN_DAYS && !d.bonusClaimed
        );
    }

    function getContractStats() external view returns (
        uint256 totalLocked,
        uint256 rewardPoolBalance,
        uint256 contractBalance,
        uint256 totalDeposits,
        bool isPaused
    ) {
        uint256 locked = gd.balanceOf(address(this));
        return (
            locked > rewardPool ? locked - rewardPool : 0,
            rewardPool,
            locked,
            depositIdCounter,
            paused()
        );
    }

    function getValidDurations() external view returns (uint16[13] memory) {
        return VALID_DURATIONS;
    }
}
