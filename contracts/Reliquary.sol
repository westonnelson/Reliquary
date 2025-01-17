// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;
pragma experimental ABIEncoderV2;

import "./Relic.sol";
import "./interfaces/ICurve.sol";
import "./interfaces/INFTDescriptor.sol";
import "./interfaces/IRewarder.sol";
import "./libraries/SignedSafeMath.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/*
 + NOTE: Maybe make BASE_OATH_PER_BLOCK an upgradable function call so we can curve that too
 + NOTE: Add UniV3's NFT metadata standard so marketplace frontends can return json data
 + NOTE: Work on quality of life abstractions and position management
*/

/*
 + @title Reliquary
 + @author Justin Bebis, Zokunei & the Byte Masons team
 + @notice Built on the MasterChefV2 system authored by Sushi's team
 +
 + @notice This system is designed to modify Masterchef accounting logic such that
 + behaviors can be programmed on a per-pool basis using a curve library. Stake in a
 + pool, also referred to as "position," is represented by means of an NFT called a 
 + "Relic." Each position has a "maturity" which captures the age of the position.
 + The curve associated with a pool modifies emissions based on each position's maturity
 + and binds it to the base rate using a per-token aggregated average.
 +
 + @notice Deposits are tracked by Relic ID instead of by user. This allows for
 + increased composability without affecting accounting logic too much, and users can
 + trade their Relics without withdrawing liquidity or affecting the position's maturity.
*/
contract Reliquary is Relic, AccessControlEnumerable, Multicall, ReentrancyGuard {
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;

    /**
     * @notice Access control roles.
     */
    bytes32 public constant OPERATOR = keccak256("OPERATOR");

    /*
     + @notice Info for each Reliquary position.
     + `amount` LP token amount the position owner has provided.
     + `rewardDebt` The amount of OATH entitled to the position owner.
     + `entry` Used to determine the entry of the position
     + `poolId` ID of the pool to which this position belongs.
    */
    struct PositionInfo {
        uint256 amount;
        int256 rewardDebt;
        uint256 entry; // position owner's relative entry into the pool.
        uint256 poolId; // ensures that a single Relic is only used for one pool.
    }

    /*
     + @notice Info of each Reliquary pool
     + `accOathPerShare` Accumulated OATH per share of pool (1 / 1e12)
     + `lastRewardTime` Last timestamp the accumulated OATH was updated
     + `allocPoint` pool's individual allocation - ratio of the total allocation
     + `averageEntry` average entry time of each share, used to determine pool maturity
     + `curveAddress` math library used to curve emissions
    */
    struct PoolInfo {
        uint256 accOathPerShare;
        uint256 lastRewardTime;
        uint256 allocPoint;
        uint256 averageEntry;
        address curveAddress;
        string underlying;
        bool isLP;
    }

    // @notice indicates whether a position's modifier is above or below the pool's average
    enum Placement {
        ABOVE,
        BELOW
    }

    // @notice indicates whether tokens are being added to, or removed from, a pool
    enum Kind {
        DEPOSIT,
        WITHDRAW
    }

    /// @notice Address of OATH contract.
    IERC20 public immutable OATH;
    /// @notice Address of NFTDescriptor contract.
    INFTDescriptor public immutable nftDescriptor;
    /// @notice Info of each Reliquary pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each Reliquary pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in Reliquary.
    IRewarder[] public rewarder;

    /// @notice Info of each staked position
    mapping(uint256 => PositionInfo) public positionForId;

    /// @notice ensures the same token isn't added to the contract twice
    mapping(address => bool) public hasBeenAdded;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 private constant EMISSIONS_PER_MILLISECOND = 1e8;
    uint256 private constant ACC_OATH_PRECISION = 1e12;
    uint256 private constant BASIS_POINTS = 10_000;

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to,
        uint256 relicId
    );
    event Withdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to,
        uint256 relicId
    );
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to,
        uint256 relicId
    );
    event Harvest(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 relicId
    );
    event LogPoolAddition(
        uint256 pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        IRewarder indexed rewarder,
        address indexed curve,
        bool isLP
    );
    event LogPoolModified(
        uint256 indexed pid,
        uint256 allocPoint,
        IRewarder indexed rewarder,
        address indexed curve,
        bool isLP
    );
    event LogUpdatePool(uint256 indexed pid, uint256 lastRewardTime, uint256 lpSupply, uint256 accOathPerShare);
    event LogInit();

    /// @param _oath The OATH token contract address.
    constructor(IERC20 _oath, INFTDescriptor _nftDescriptor) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        OATH = _oath;
        nftDescriptor = _nftDescriptor;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        require(_exists(tokenId));
        PositionInfo storage position = positionForId[tokenId];
        PoolInfo storage pool = poolInfo[position.poolId];
        uint256 maturity = (_timestamp() - position.entry) / 1000;
        return nftDescriptor.constructTokenURI(
            INFTDescriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                isLP: pool.isLP,
                underlying: pool.underlying,
                underlyingAddress: address(lpToken[position.poolId]),
                poolId: position.poolId,
                amount: position.amount,
                pendingOath: pendingOath(tokenId),
                maturity: maturity,
                curveAddress: pool.curveAddress
            })
        );
    }

    /// @notice Returns the number of Reliquary pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /*
     + @notice Add a new pool for the specified LP.
     +         Can only be called by the owner.
     +
     + @param allocPoint the allocation points for the new pool
     + @param _lpToken address of the pooled ERC-20 token
     + @param _rewarder Address of the rewarder delegate
     + @param curve Address of the curve library
    */
    function addPool(
        uint256 allocPoint,
        IERC20 _lpToken,
        IRewarder _rewarder,
        ICurve curve,
        string memory underlying,
        bool isLP
    ) public onlyRole(OPERATOR) {
        require(!hasBeenAdded[address(_lpToken)], "this token has already been added");
        require(_lpToken != OATH, "same token");

        totalAllocPoint += allocPoint;
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(
            PoolInfo({
                allocPoint: allocPoint,
                lastRewardTime: _timestamp(),
                accOathPerShare: 0,
                averageEntry: 0,
                curveAddress: address(curve),
                underlying: underlying,
                isLP: isLP
            })
        );
        hasBeenAdded[address(_lpToken)] = true;

        emit LogPoolAddition((lpToken.length - 1), allocPoint, _lpToken, _rewarder, address(curve), isLP);
    }

    /*
     + @notice Modify the given pool's properties.
     +         Can only be called by the owner.
     +
     + @param pid The index of the pool. See `poolInfo`.
     + @param allocPoint New AP of the pool.
     + @param _rewarder Address of the rewarder delegate.
     + @param curve Address of the curve library
     + @param overwriteRewarder True if _rewarder should be set. Otherwise `_rewarder` is ignored.
     + @param overwriteCurve True if curve should be set. Otherwise `curve` is ignored.
    */
    function modifyPool(
        uint256 pid,
        uint256 allocPoint,
        IRewarder _rewarder,
        ICurve curve,
        string memory underlying,
        bool isLP,
        bool overwriteRewarder
    ) public onlyRole(OPERATOR) {
        require(pid < poolInfo.length, "set: pool does not exist");
        require(address(curve) != address(0), "invalid curve address");

        PoolInfo storage pool = poolInfo[pid];
        totalAllocPoint -= pool.allocPoint;
        totalAllocPoint += allocPoint;
        pool.allocPoint = allocPoint;

        if (overwriteRewarder) {
            rewarder[pid] = _rewarder;
        }

        pool.curveAddress = address(curve);
        pool.underlying = underlying;
        pool.isLP = isLP;

        emit LogPoolModified(pid, allocPoint, overwriteRewarder ? _rewarder : rewarder[pid], address(curve), isLP);
    }

    /*
     + @notice View function to see pending OATH on frontend.
     + @param _relicId ID of the position.
     + @return pending OATH reward for a given position owner.
    */
    function pendingOath(uint256 _relicId) public view returns (uint256 pending) {
        _ensureValidPosition(_relicId);

        PositionInfo storage position = positionForId[_relicId];
        PoolInfo storage pool = poolInfo[position.poolId];
        uint256 accOathPerShare = pool.accOathPerShare;
        uint256 lpSupply = _poolBalance(position.poolId);

        uint256 millisSinceReward = _timestamp() - pool.lastRewardTime;
        if (millisSinceReward != 0 && lpSupply != 0) {
            uint256 oathReward = (millisSinceReward * EMISSIONS_PER_MILLISECOND * pool.allocPoint) / totalAllocPoint;
            accOathPerShare += (oathReward * ACC_OATH_PRECISION) / lpSupply;
        }

        int256 rawPending = int256((position.amount * accOathPerShare) / ACC_OATH_PRECISION) - position.rewardDebt;
        pending = _calculateEmissions(rawPending.toUInt256(), _relicId);
    }

    /*
     + @notice Update reward variables for all pools. Be careful of gas spending!
     + @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    */
    function massUpdatePools(uint256[] calldata pids) external nonReentrant {
        for (uint256 i = 0; i < pids.length; i++) {
            _updatePool(pids[i]);
        }
    }

    /*
     + @notice Update reward variables of the given pool.
     + @param pid The index of the pool. See `poolInfo`.
     + @return pool Returns the pool that was updated.
    */
    function updatePool(uint256 pid) external nonReentrant {
        _updatePool(pid);
    }

    /*
     + @dev Internal updatePool function without nonReentrant modifier
    */
    function _updatePool(uint256 pid) internal {
        PoolInfo storage pool = poolInfo[pid];
        uint256 millisSinceReward = _timestamp() - pool.lastRewardTime;

        if (millisSinceReward != 0) {
            uint256 lpSupply = _poolBalance(pid);

            if (lpSupply != 0) {
                uint256 oathReward = (millisSinceReward * EMISSIONS_PER_MILLISECOND * pool.allocPoint) /
                    totalAllocPoint;
                pool.accOathPerShare += (oathReward * ACC_OATH_PRECISION) / lpSupply;
            }

            pool.lastRewardTime = _timestamp();

            emit LogUpdatePool(pid, pool.lastRewardTime, lpSupply, pool.accOathPerShare);
        }
    }

    function createRelicAndDeposit(
        address to,
        uint256 pid,
        uint256 amount
    ) public returns (uint256 id) {
        require(pid < poolInfo.length, "invalid pool ID");
        id = mint(to);
        positionForId[id].poolId = pid;
        _deposit(amount, id);
    }

    /*
     + @notice Deposit LP tokens to Reliquary for OATH allocation.
     + @param _amount token amount to deposit.
     + @param _relicId NFT ID of the receiver of `amount` deposit benefit.
    */
    function deposit(uint256 amount, uint256 _relicId) external nonReentrant {
        _ensureValidPosition(_relicId);
        _deposit(amount, _relicId);
    }

    /*
     + @dev Internal deposit function that assumes _relicId is valid.
    */
    function _deposit(uint256 amount, uint256 _relicId) internal {
        require(amount != 0, "depositing 0 amount");
        PositionInfo storage position = positionForId[_relicId];

        _updatePool(position.poolId);
        _updateEntry(amount, _relicId);
        _updateAverageEntry(position.poolId, amount, Kind.DEPOSIT);

        PoolInfo storage pool = poolInfo[position.poolId];

        position.amount += amount;
        position.rewardDebt += int256((amount * pool.accOathPerShare) / ACC_OATH_PRECISION);

        IRewarder _rewarder = rewarder[position.poolId];
        address to = ownerOf(_relicId);
        if (address(_rewarder) != address(0)) {
            _rewarder.onOathReward(position.poolId, to, to, 0, position.amount);
        }

        lpToken[position.poolId].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, position.poolId, amount, to, _relicId);
    }

    /*
     + @notice Withdraw LP tokens from Reliquary.
     + @param amount LP token amount to withdraw.
     + @param _relicId NFT ID of the receiver of the tokens.
    */
    function withdraw(uint256 amount, uint256 _relicId) public nonReentrant {
        _ensureValidPosition(_relicId);
        address to = ownerOf(_relicId);
        require(to == msg.sender, "you do not own this position");
        require(amount != 0, "withdrawing 0 amount");

        PositionInfo storage position = positionForId[_relicId];
        _updatePool(position.poolId);

        PoolInfo storage pool = poolInfo[position.poolId];

        // Effects
        position.rewardDebt -= int256((amount * pool.accOathPerShare) / ACC_OATH_PRECISION);
        position.amount -= amount;
        _updateEntry(amount, _relicId);
        _updateAverageEntry(position.poolId, amount, Kind.WITHDRAW);

        // Interactions
        IRewarder _rewarder = rewarder[position.poolId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onOathReward(position.poolId, msg.sender, to, 0, position.amount);
        }

        lpToken[position.poolId].safeTransfer(to, amount);
        if (position.amount == 0) {
            burn(_relicId);
            delete (positionForId[_relicId]);
        }

        emit Withdraw(msg.sender, position.poolId, amount, to, _relicId);
    }

    /*
     + @notice Harvest proceeds for transaction sender to owner of `_relicId`.
     + @param _relicId NFT ID of the receiver of OATH rewards.
    */
    function harvest(uint256 _relicId) public nonReentrant {
        _ensureValidPosition(_relicId);
        address to = ownerOf(_relicId);
        require(to == msg.sender, "you do not own this position");

        PositionInfo storage position = positionForId[_relicId];
        _updatePool(position.poolId);

        PoolInfo storage pool = poolInfo[position.poolId];

        int256 accumulatedOath = int256((position.amount * pool.accOathPerShare) / ACC_OATH_PRECISION);
        uint256 _pendingOath = (accumulatedOath - position.rewardDebt).toUInt256();
        uint256 _curvedOath = _calculateEmissions(_pendingOath, _relicId);

        // Effects
        position.rewardDebt = accumulatedOath;

        // Interactions
        if (_curvedOath != 0) {
            OATH.safeTransfer(to, _curvedOath);
        }

        IRewarder _rewarder = rewarder[position.poolId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onOathReward(position.poolId, msg.sender, to, _curvedOath, position.amount);
        }

        emit Harvest(msg.sender, position.poolId, _curvedOath, _relicId);
    }

    /*
     + @notice Withdraw LP tokens and harvest proceeds for transaction sender to owner of `_relicId`.
     + @param amount token amount to withdraw.
     + @param _relicId NFT ID of the receiver of the tokens and OATH rewards.
    */
    function withdrawAndHarvest(uint256 amount, uint256 _relicId) public nonReentrant {
        _ensureValidPosition(_relicId);
        address to = ownerOf(_relicId);
        require(to == msg.sender, "you do not own this position");
        require(amount != 0, "withdrawing 0 amount");

        PositionInfo storage position = positionForId[_relicId];
        _updatePool(position.poolId);

        PoolInfo storage pool = poolInfo[position.poolId];
        int256 accumulatedOath = int256((position.amount * pool.accOathPerShare) / ACC_OATH_PRECISION);
        uint256 _pendingOath = (accumulatedOath - position.rewardDebt).toUInt256();
        uint256 _curvedOath = _calculateEmissions(_pendingOath, _relicId);

        if (_curvedOath != 0) {
            OATH.safeTransfer(to, _curvedOath);
        }

        position.rewardDebt = accumulatedOath - int256((amount * pool.accOathPerShare) / ACC_OATH_PRECISION);
        position.amount -= amount;
        _updateEntry(amount, _relicId);
        _updateAverageEntry(position.poolId, amount, Kind.WITHDRAW);

        IRewarder _rewarder = rewarder[position.poolId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onOathReward(position.poolId, msg.sender, to, _curvedOath, position.amount);
        }

        lpToken[position.poolId].safeTransfer(to, amount);
        if (position.amount == 0) {
            burn(_relicId);
            delete (positionForId[_relicId]);
        }

        emit Withdraw(msg.sender, position.poolId, amount, to, _relicId);
        emit Harvest(msg.sender, position.poolId, _curvedOath, _relicId);
    }

    /*
     + @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     + @param _relicId NFT ID of the receiver of the tokens.
    */
    function emergencyWithdraw(uint256 _relicId) public nonReentrant {
        _ensureValidPosition(_relicId);
        address to = ownerOf(_relicId);
        require(to == msg.sender, "you do not own this position");

        PositionInfo storage position = positionForId[_relicId];
        uint256 amount = position.amount;

        position.amount = 0;
        position.rewardDebt = 0;
        _updateEntry(amount, _relicId);
        _updateAverageEntry(position.poolId, amount, Kind.WITHDRAW);

        IRewarder _rewarder = rewarder[position.poolId];
        if (address(_rewarder) != address(0)) {
            _rewarder.onOathReward(position.poolId, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[position.poolId].safeTransfer(to, amount);
        burn(_relicId);
        delete (positionForId[_relicId]);

        emit EmergencyWithdraw(msg.sender, position.poolId, amount, to, _relicId);
    }

    /*
     + @notice pulls Reliquary data and passes it to the curve library
     + @param _relicId - ID of the position whose maturity curve you'd like to see
    */
    function curved(uint256 _relicId) public view returns (uint256 _curved) {
        PositionInfo storage position = positionForId[_relicId];
        PoolInfo memory pool = poolInfo[position.poolId];

        uint256 maturity = (_timestamp() - position.entry) / 1000;

        _curved = ICurve(pool.curveAddress).curve(maturity);
    }

    /*
     + @notice operates on the position's base emissions
     + @param amount OATH amount to modify
     + @param _relicId ID of the position that's being modified
    */
    function _calculateEmissions(uint256 amount, uint256 _relicId) internal view returns (uint256 emissions) {
        (uint256 distance, Placement placement) = _calculateDistanceFromMean(_relicId);

        if (placement == Placement.ABOVE) {
            emissions = (amount * (BASIS_POINTS + distance)) / BASIS_POINTS;
        } else if (placement == Placement.BELOW) {
            emissions = (amount * (BASIS_POINTS - distance)) / BASIS_POINTS;
        } else {
            emissions = amount;
        }
    }

    /*
     + @notice calculates how far the user's position maturity is from the average
     + @param _relicId NFT ID of the position being assessed
    */
    function _calculateDistanceFromMean(uint256 _relicId)
        internal
        view
        returns (uint256 distance, Placement placement)
    {
        PositionInfo storage positionInfo = positionForId[_relicId];

        uint256 position = curved(_relicId);
        uint256 mean = _calculateMean(positionInfo.poolId);

        if (position < mean) {
            distance = (mean - position) * BASIS_POINTS;
            placement = Placement.BELOW;
        } else {
            distance = (position - mean) * BASIS_POINTS;
            placement = Placement.ABOVE;
        }
    }

    /*
     + @notice calculates the average position of every token on the curve
     + @pid pid The index of the pool. See `poolInfo`.
     + @return the Y value based on X maturity in the context of the curve
    */

    function _calculateMean(uint256 pid) internal view returns (uint256 mean) {
        PoolInfo memory pool = poolInfo[pid];
        uint256 maturity = (_timestamp() - pool.averageEntry) / 1000;
        mean = ICurve(pool.curveAddress).curve(maturity);
    }

    /*
     + @notice updates the average entry time of each token in the pool
     + @param pid The index of the pool. See `poolInfo`.
     + @param amount the amount of tokens being accounted for
     + @param kind the action being performed (deposit / withdrawal)
    */

    function _updateAverageEntry(
        uint256 pid,
        uint256 amount,
        Kind kind
    ) internal returns (bool success) {
        PoolInfo storage pool = poolInfo[pid];
        uint256 lpSupply = _poolBalance(pid);
        if (lpSupply == 0) {
            pool.averageEntry = _timestamp();
            return true;
        } else {
            uint256 weight = (amount * 1e18) / lpSupply;
            uint256 maturity = _timestamp() - pool.averageEntry;
            if (kind == Kind.DEPOSIT) {
                pool.averageEntry += ((maturity * weight) / 1e18);
            } else {
                pool.averageEntry -= ((maturity * weight) / 1e18);
            }
            return true;
        }
    }

    /*
     + @notice updates the user's entry time based on the weight of their deposit or withdrawal
     + @param amount the amount of the deposit / withdrawal
     + @param _relicId the NFT ID of the position being updated
    */

    function _updateEntry(uint256 amount, uint256 _relicId) internal returns (bool success) {
        PositionInfo storage position = positionForId[_relicId];
        if (position.amount == 0) {
            position.entry = _timestamp();
            return true;
        }
        uint256 weight = (amount * BASIS_POINTS) / position.amount;
        uint256 maturity = _timestamp() - position.entry;
        position.entry += ((maturity * weight) / BASIS_POINTS);
        return true;
    }

    /*
     + @notice returns the total deposits of the pool's token
     + @param pid The index of the pool. See `poolInfo`.
     + @return the amount of pool tokens held by the contract
    */

    function _poolBalance(uint256 pid) internal view returns (uint256 total) {
        total = IERC20(lpToken[pid]).balanceOf(address(this));
    }

    // Converting timestamp to miliseconds so precision isn't lost when we mutate the
    // user's entry time.

    function _timestamp() internal view returns (uint256 timestamp) {
        timestamp = block.timestamp * 1000;
    }

    /*
     + @dev Existing position is valid iff it has non-zero amount.
    */
    function _ensureValidPosition(uint256 _relicId) internal view {
        PositionInfo storage position = positionForId[_relicId];
        require(position.amount != 0, "invalid position ID");
    }
}
