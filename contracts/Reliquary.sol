// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./boring-solidity/libraries/BoringMath.sol";
import "./OZ/utils/Multicall.sol";
import "./OZ/access/Ownable.sol";
import "./OZ/token/ERC20/utils/SafeERC20.sol";
import "./OZ/token/ERC20/IERC20.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./Memento.sol";

interface ICurve {
    function curve(uint maturity) external pure returns (uint);
}

/*
 + NOTE: Maybe make BASE_RELIC_PER_BLOCK an upgradable function call so we can curve that too
 + NOTE: Add UniV3's NFT metadata standard so marketplace frontends can return json data
 + NOTE: Work on quality of life abstractions and position management
*/

/*
 + @title Reliquary
 + @author Justin Bebis & the Byte Masons team
 + @notice Built on the MasterChefV2 system authored by Sushi's team
 +
 + @notice This system is designed to modify Masterchef accounting logic such that
 + behaviors can be programmed per-pool using a curve library, which modifies emissions
 + based on position maturity and binds it to the base rate using a per-token aggregated
 + average
 +
 + @notice Deposits are tracked by position instead of by user, and mapped to an individual
 + NFT as opposed to an EOA. This allows for increased composability without affecting
 + accounting logic too much, and users can exit their position without withdrawing
 + their liquidity or sacrificing their position's maturity.
*/
contract Reliquary is Memento, Ownable, Multicall {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;

    /*
     + @notice Info for each Reliquary position.
     + `amount` LP token amount the position owner has provided.
     + `rewardDebt` The amount of RELIC entitled to the position owner.
     + `entry` Used to determine the entry of the position
    */
    struct PositionInfo {
        uint256 amount;
        int256 rewardDebt;

        uint entry; // position owner's relative entry into the pool.
        bool exempt; // exemption from vesting cliff.
        uint poolId;
    }

    /*
     + @notice Info of each Reliquary pool
     + `accRelicPerShare` Accumulated relic per share of pool (1 / 1e12)
     + `lastRewardTime` Last timestamp the accumulated relic was updated
     + `allocPoint` pool's individual allocation - ratio of the total allocation
     + `averageEntry` average entry time of each share, used to determine pool maturity
     + `curveAddress` math library used to curve emissions
    */
    struct PoolInfo {
        uint128 accRelicPerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;

        uint averageEntry;
        address curveAddress;
    }

    /*
     + @notice used to determine position's emission modifier
     + `param` distance the % distance the position is from the curve, in base 10000
     + `param` placement flag to note whether position is above or below the average maturity
    */

    struct Position {
      uint distance;
      Placement placement;
    }

    // @notice used to determine whether a position is above or below the average curve
    enum Placement { ABOVE, BELOW }

    // @notice used to determine whether the average entry is increased or decreased
    enum Kind { DEPOSIT, WITHDRAW }

    /// @notice Address of RELIC contract.
    IERC20 public immutable RELIC;
    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each staked position
    mapping (uint256 => PositionInfo) public positionInfo;

    /// @notice ensures the same token isn't added to the contract twice
    mapping (address => bool) public hasBeenAdded;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 private constant BASE_RELIC_PER_SECOND = 1e12;
    uint256 private constant ACC_RELIC_PRECISION = 1e12;
    uint256 private constant CURVE_PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to, uint positionId);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to, uint positionId);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to, uint positionId);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount, uint positionId);
    event LogPoolAddition(uint256 pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarder indexed rewarder, address indexed curve);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, address indexed curve);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardTime, uint256 lpSupply, uint256 accRELICPerShare);
    event LogInit();

    /// @param _relic The RELIC token contract address.
    constructor(IERC20 _relic) {
        RELIC = _relic;
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /*
     + @notice Add a new LP to the pool. Can only be called by the owner.
     + @param allocPoint the allocation points for the new pool
     + @param _lpToken address of the pooled ERC-20 token
     + @param _rewarder Address of the rewarder delegate
    */
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarder _rewarder, ICurve _curve) public onlyOwner {
        require(!hasBeenAdded[address(_lpToken)], "this token has already been added");
        uint256 lastRewardTime = _timestamp();
        totalAllocPoint = (totalAllocPoint + allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardTime: lastRewardTime.to64(),
            accRelicPerShare: 0,
            averageEntry: 0,
            curveAddress: address(_curve)
        }));
        hasBeenAdded[address(_lpToken)] = true;
        emit LogPoolAddition((lpToken.length - 1), allocPoint, _lpToken, _rewarder, address(_curve));
    }

    /*
     + @notice Update the given pool's RELIC allocation point and `IRewarder` contract
     + @param _pid The index of the pool. See `poolInfo`.
     + @param _allocPoint New AP of the pool.
     + @param _rewarder Address of the rewarder delegate.
     + @param _curve Address of the curve library
     + @param overwriteRewarder True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
     + @param overwriteCurve True if _curve should be `set`. Otherwise `_curve` is ignored.
    */
    function set(
      uint256 _pid,
      uint256 _allocPoint,
      IRewarder _rewarder,
      address _curve,
      bool overwriteRewarder,
      bool overwriteCurve
    ) public onlyOwner {
        totalAllocPoint = (totalAllocPoint - poolInfo[_pid].allocPoint) + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (overwriteRewarder) { rewarder[_pid] = _rewarder; }
        if (overwriteCurve) { poolInfo[_pid].curveAddress = _curve; }
        emit LogSetPool(_pid, _allocPoint, overwriteRewarder ? _rewarder : rewarder[_pid], overwriteCurve ? _curve : poolInfo[_pid].curveAddress);
    }

    /*
     + @notice View function to see pending RELIC on frontend.
     + @param _pid The index of the pool. See `poolInfo`.
     + @param _positionId ID of the position.
     + @return pending RELIC reward for a given position owner.
    */
    function pendingRelic(uint256 positionId) external view returns (uint256 pending) {
        PositionInfo storage position = positionInfo[positionId];
        uint _pid = position.poolId;
        PoolInfo memory pool = poolInfo[_pid];
        uint256 accRelicPerShare = pool.accRelicPerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (_timestamp() > pool.lastRewardTime && lpSupply != 0) {
            uint256 secs = _timestamp() - pool.lastRewardTime;
            uint256 relicReward = ((secs * BASE_RELIC_PER_SECOND) * pool.allocPoint) / totalAllocPoint;
            accRelicPerShare = ((accRelicPerShare + relicReward) * ACC_RELIC_PRECISION) / lpSupply;
        }
        uint256 rawPending = (int256(position.amount * accRelicPerShare / ACC_RELIC_PRECISION) - position.rewardDebt).toUInt256();
        pending = _modifyEmissions(rawPending, positionId, _pid);
    }

    /*
     + @notice Update reward variables for all pools. Be careful of gas spending!
     + @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    */
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /*
     + @notice Update reward variables of the given pool.
     + @param pid The index of the pool. See `poolInfo`.
     + @return pool Returns the pool that was updated.
    */
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (_timestamp() > pool.lastRewardTime) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 secs = _timestamp() - pool.lastRewardTime;
                uint256 relicReward = secs * BASE_RELIC_PER_SECOND * pool.allocPoint / totalAllocPoint;
                pool.accRelicPerShare = pool.accRelicPerShare + ((relicReward * ACC_RELIC_PRECISION / lpSupply).to128());
            }
            pool.lastRewardTime = _timestamp().to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardTime, lpSupply, pool.accRelicPerShare);
        }
    }

    function createPositionAndDeposit(address to, uint256 pid, uint256 amount) public returns (uint) {
      uint id = createNewPosition(to, pid);
      deposit(amount, id);
      return id;
    }

    function createNewPosition(address to, uint256 pid) public returns (uint) {
      uint id = mint(to, pid);
      return id;
    }

    /*
     + @notice Deposit LP tokens to Reliquary for RELIC allocation.
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount token amount to deposit.
     + @param positionId NFT ID of the receiver of `amount` deposit benefit.
    */
    function deposit(uint256 pid, uint256 amount, uint256 positionId) public {
        PoolInfo memory pool = updatePool(pid);
        _updateAverageEntry(pid, amount, Kind.DEPOSIT);
        address to = ownerOf(positionId);

        // Effects
        position.amount = position.amount + amount;
        position.rewardDebt = position.rewardDebt + (int256(amount * pool.accRelicPerShare / ACC_RELIC_PRECISION));

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onRelicReward(pid, to, to, 0, position.amount);
        }

        _updateEntry(amount, positionId);
        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to, positionId);
    }

    /*
     + @notice Withdraw LP tokens from Reliquary.
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount LP token amount to withdraw.
     + @param positionId NFT ID of the receiver of the tokens.
    */
    function withdraw(uint256 pid, uint256 amount, uint256 positionId) public {
        PoolInfo memory pool = updatePool(pid);
        _updateAverageEntry(pid, amount, Kind.WITHDRAW);
        PositionInfo storage position = positionInfo[pid][positionId];
        address to = ownerOf(positionId);

        // Effects
        position.rewardDebt = position.rewardDebt - (int256(amount * pool.accRelicPerShare / ACC_RELIC_PRECISION));
        position.amount = position.amount - amount;

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onRelicReward(pid, msg.sender, to, 0, position.amount);
        }

        _updateEntry(pid, amount, positionId);
        _updateAverageEntry(pid, amount, Kind.WITHDRAW);
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to, positionId);
    }

    /*
     + @notice Harvest proceeds for transaction sender to `to`.
     + @param pid The index of the pool. See `poolInfo`.
     + @param positionId NFT ID of the receiver of RELIC rewards.
    */
    function harvest(uint256 pid, uint256 positionId) public {
        PoolInfo memory pool = updatePool(pid);
        address to = ownerOf(positionId);
        int256 accumulatedRelic = int256(position.amount * pool.accRelicPerShare / ACC_RELIC_PRECISION);
        uint256 _pendingRelic = (accumulatedRelic - position.rewardDebt).toUInt256();
        uint256 _curvedRelic = _modifyEmissions(_pendingRelic, positionId, pid);

        // Effects
        position.rewardDebt = accumulatedRelic;

        // Interactions
        if (_pendingRelic != 0) {
            RELIC.safeTransfer(to, _curvedRelic);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onRelicReward( pid, msg.sender, to, _pendingRelic, position.amount);
        }

        emit Harvest(msg.sender, pid, _curvedRelic, positionId);
    }

    /*
     + @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount token amount to withdraw.
     + @param positionId NFT ID of the receiver of the tokens and RELIC rewards.
    */
    function withdrawAndHarvest(uint256 pid, uint256 amount, uint256 positionId) public {
        PoolInfo memory pool = updatePool(pid);
        _updateAverageEntry(pid, amount, Kind.WITHDRAW);
        address to = ownerOf(positionId);
        int256 accumulatedRelic = int256(position.amount * pool.accRelicPerShare / ACC_RELIC_PRECISION);
        uint256 _pendingRelic = (accumulatedRelic - position.rewardDebt).toUInt256();
        uint256 _curvedRelic = _modifyEmissions(_pendingRelic, positionId, pid);

        // Effects
        position.rewardDebt = accumulatedRelic - int256(amount * pool.accRelicPerShare / ACC_RELIC_PRECISION);
        position.amount = position.amount - amount;

        // Interactions
        RELIC.safeTransfer(to, _curvedRelic);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onRelicReward(pid, msg.sender, to, _curvedRelic, position.amount);
        }

        _updateEntry(pid, amount, positionId);
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to, positionId);
        emit Harvest(msg.sender, pid, _pendingRelic, positionId);
    }

    /*
     + @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     + @param pid The index of the pool. See `poolInfo`.
     + @param positionId NFT ID of the receiver of the tokens.
    */
    function emergencyWithdraw(uint256 pid, uint256 positionId) public {
        PositionInfo storage position = positionInfo[pid][positionId];
        uint256 amount = position.amount;
        address to = ownerOf(positionId);
        uint pid = position.poolId;
        _updateAverageEntry(pid, amount, Kind.WITHDRAW);
        position.amount = 0;
        position.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onRelicReward(pid, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        burn(positionId);
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to, positionId);
    }

    /*
     + @notice pulls MasterChef data and passes it to the curve library
     + @param positionId - the position whose maturity curve you'd like to see
     + @param pid The index of the pool. See `poolInfo`.
    */

    function curved(uint positionId) public view returns (uint) {
      PositionInfo memory position = positionInfo[positionId];
      PoolInfo memory pool = poolInfo[position.poolId];

      uint maturity = _timestamp() - position.entry;

      return ICurve(pool.curveAddress).curve(maturity);
    }

    /*
     + @notice operates on the position's MasterChef emissions
     + @param amount RELIC amount to modify
     + @param positionId the position that's being modified
     + @param pid The index of the pool. See `poolInfo`.
    */

    function _modifyEmissions(uint amount, uint positionId, uint pid) internal view returns (uint) {
      Position memory position = _calculateDistanceFromMean(positionId, pid);

      if (position.placement == Placement.ABOVE) {
        return amount * (BASIS_POINTS + position.distance) / BASIS_POINTS;
      } else if (position.placement == Placement.BELOW) {
        return amount * (BASIS_POINTS - position.distance) / BASIS_POINTS;
      } else {
        return amount;
      }
    }

    /*
     + @notice calculates how far the user's position maturity is from the average
     + @param positionId NFT ID of the position being assessed
     + @param pid The index of the pool. See `poolInfo`.
    */

    function _calculateDistanceFromMean(uint positionId, uint pid) internal view returns (Position memory) {
      uint position = curved(positionId);
      uint mean = _calculateMean(pid);

      if (position < mean) {
        return Position((mean - position)*BASIS_POINTS/mean, Placement.BELOW);
      } else {
        return Position((position - mean)*BASIS_POINTS/mean, Placement.ABOVE);
      }
    }

    /*
     + @notice calculates the average position of every token on the curve
     + @pid pid The index of the pool. See `poolInfo`.
     + @return the Y value based on X maturity in the context of the curve
    */

    function _calculateMean(uint pid) internal view returns (uint) {
      PoolInfo memory pool = poolInfo[pid];
      uint maturity = _timestamp() - pool.averageEntry;
      return ICurve(pool.curveAddress).curve(maturity);
    }

    /*
     + @notice calculates the weight of a withdraw/deposit compared to the system total
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount the number being weighted
    */

    function _calculateWeight(uint pid, uint amount) internal view returns (uint) {
      return amount * CURVE_PRECISION / _totalDeposits(pid);
    }

    /*
     + @notice updates the average entry time of each token in the pool
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount the amount of tokens being accounted for
     + @param kind the action being performed (deposit / withdrawal)
    */

    function _updateAverageEntry(uint pid, uint amount, Kind kind) internal returns (bool) {
      PoolInfo storage pool = poolInfo[pid];
      uint256 lpSupply = _totalDeposits(pid);
      if (lpSupply == 0) {
        pool.averageEntry = _timestamp();
        return true;
      } else {
        uint weight = amount * 1e18 / lpSupply;
        uint maturity = _timestamp() - pool.averageEntry;
        if (kind == Kind.DEPOSIT) {
          pool.averageEntry += (maturity * weight / 1e18);
        } else {
          pool.averageEntry -= (maturity * weight / 1e18);
        }
        return true;
      }
    }

    /*
     + @notice updates the user's entry time based on the weight of their deposit or withdrawal
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount the amount of the deposit / withdrawal
     + @param positionId the NFT ID of the position being updated
    */

    function _updateEntry(uint amount, uint positionId) internal returns (bool) {
      PositionInfo storage position = positionInfo[positionId];
      uint weight = amount * BASIS_POINTS / position.amount;
      uint maturity = _timestamp() - position.entry;
      position.entry += (maturity * weight / BASIS_POINTS);
      return true;
    }

    /*
     + @notice returns the total deposits of the pool's token
     + @param pid The index of the pool. See `poolInfo`.
     + @return the amount of pool tokens held by the contract
    */

    function _totalDeposits(uint pid) internal view returns (uint256) {
      return IERC20(lpToken[pid]).balanceOf(address(this));
    }

    function _timestamp() internal view returns (uint) {
      return block.timestamp * 1000;
    }
}
