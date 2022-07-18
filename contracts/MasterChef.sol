// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IToken.sol";
import "./Treasure.sol";

// import "@nomiclabs/buidler/console.sol";

interface IMigratorChef {
    // Perform LP token migration from legacy PancakeSwap to CakeSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to PancakeSwap LP tokens.
    // CakeSwap must mint EXACTLY the same amount of CakeSwap LP tokens or
    // else something bad will happen. Traditional PancakeSwap does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Cake. He can make Cake and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CAKE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CAKEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCakePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCakePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardBlock; // Last block number that CAKEs distribution occurs.
        uint256 accCakePerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    struct ExtraRewardInfo {
        address token;
        uint256 rewardPerBlock;
        uint256 totalAllocPoint;
        bool enabled;
    }

    ExtraRewardInfo[] public extraRewardTokens;
    mapping(uint256 => mapping(uint256 => uint256)) poolAllocPoint;
    mapping(uint256 => mapping(uint256 => uint256)) poolAccTokenPerShare;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) poolUserRewardDebt;

    // The CAKE TOKEN!
    IToken public rewardToken;

    // The Treasure address.
    Treasure public treasure;

    // Dev address.
    address public devaddr;
    // TOKEN tokens created per block.
    uint256 public tokenPerBlock;
    // Bonus muliplier for early cake makers.
    uint256 public BONUS_MULTIPLIER = 1;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CAKE mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        IToken _rewardToken,
        Treasure _treasure,
        address _devaddr,
        uint256 _tokenPerBlock,
        uint256 _startBlock
    ) {
        rewardToken = _rewardToken;
        treasure = _treasure;
        devaddr = _devaddr;
        tokenPerBlock = _tokenPerBlock;
        startBlock = _startBlock;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({lpToken : _lpToken, allocPoint : _allocPoint, lastRewardBlock : lastRewardBlock, accCakePerShare : 0})
        );
    }

    // Update the given pool's CAKE allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }


    /*struct ExtraRewardInfo {
        address token;
        uint256 rewardPerBlock;
        uint256 totalAllocPoint;
        mapping(uint256 => uint256) poolAllocPoint;
        mapping(uint256 => uint256) poolAccTokenPerShare;
        mapping(uint256 => mapping(address => uint256)) poolUserRewardDebt;
        bool enabled;
    }*/
    function addExtra(
        address _token,
        uint256 _rewardPerBlock,
        uint256[] calldata _pools,
        uint256[] calldata _poolAllocPoints,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        require(_pools.length == _poolAllocPoints.length, 'length err');
        ExtraRewardInfo memory info = ExtraRewardInfo({token : _token, rewardPerBlock : _rewardPerBlock, totalAllocPoint : 0, enabled : true});

        uint256 exId = extraRewardTokens.length;
        uint256 _totalAlloc;
        for (uint256 i = 0; i < _pools.length; i ++) {
            poolAllocPoint[exId][_pools[i]] = _poolAllocPoints[i];
            _totalAlloc = _totalAlloc.add(_poolAllocPoints[i]);
        }
        info.totalAllocPoint = _totalAlloc;
        extraRewardTokens.push(info);
    }

    function setExtra(
        uint256 _exId,
        uint256 _rewardPerBlock,
        uint256[] calldata _pools,
        uint256[] calldata _poolAllocPoints,
        bool _enabled,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        ExtraRewardInfo memory info = extraRewardTokens[_exId];
        info.enabled = _enabled;
        info.rewardPerBlock = _rewardPerBlock;
        if (_pools.length > 0) {
            require(_pools.length == _poolAllocPoints.length, 'length err');
            uint256 _totalAlloc;
            for (uint256 i = 0; i < _pools.length; i ++) {
                poolAllocPoint[_exId][_pools[i]] = _poolAllocPoints[i];
                _totalAlloc = _totalAlloc.add(_poolAllocPoints[i]);
            }
            info.totalAllocPoint = _totalAlloc;
        }

        extraRewardTokens[_exId] = info;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending TOKENs on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCakePerShare = pool.accCakePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCakePerShare = accCakePerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accCakePerShare).div(1e12).sub(user.rewardDebt);
    }

    function pendingExtraRewards(uint256 _pid, address _user) external view returns (uint256[] memory) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        bool hasNewReward = block.number > pool.lastRewardBlock && lpSupply != 0;

        ExtraRewardInfo storage info;
        uint256[] memory amounts = new uint256[](extraRewardTokens.length);
        uint256 share;
        uint256 exReward;
        for (uint256 i = 0; i < extraRewardTokens.length; i ++) {
            info = extraRewardTokens[i];
            share = poolAccTokenPerShare[i][_pid];
            if (hasNewReward) {
                exReward = tokenPerBlock.mul(pool.allocPoint).div(totalAllocPoint);
                share = share.add(exReward.mul(1e12).div(lpSupply));
            }
            amounts[i] = user.amount.mul(share).div(1e12).sub(poolUserRewardDebt[i][_pid][_user]);
        }
        return amounts;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        rewardToken.mint(devaddr, tokenReward.div(5));
        pool.accCakePerShare = pool.accCakePerShare.add(tokenReward.mul(1e12).div(lpSupply));
        _updateExtraRewards(_pid, lpSupply);
        pool.lastRewardBlock = block.number;
    }

    function _updateExtraRewards(uint256 _pid, uint256 lpSupply) internal {
        ExtraRewardInfo storage info;
        uint256 exReward;
        for (uint256 i = 0; i < extraRewardTokens.length; i ++) {
            info = extraRewardTokens[i];
            if (info.enabled) {
                exReward = info.rewardPerBlock.mul(poolAllocPoint[i][_pid]).div(info.totalAllocPoint);
                poolAccTokenPerShare[i][_pid] = poolAccTokenPerShare[i][_pid].add(exReward.mul(1e12).div(lpSupply));
            }
        }
    }

    // Claim rewards.
    function claim(uint256 _pid) public {

    }

    // Deposit LP tokens to MasterChef for CAKE allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeTokenTransfer(msg.sender, pending);
            }

            _updateExtraRewards(_pid, msg.sender);
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
        _updateUserExtraRewardDebt(_pid, msg.sender, user.amount);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accCakePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeTokenTransfer(msg.sender, pending);
        }
        _updateExtraRewards(_pid, msg.sender);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCakePerShare).div(1e12);
        _updateUserExtraRewardDebt(_pid, msg.sender, user.amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        _updateUserExtraRewardDebt(_pid, msg.sender, 0);
    }

    // Safe cake transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        treasure.safeTokenTransfer(address(rewardToken), _to, _amount);
    }

    function safeExtraRewardTokenTransfer(address _tokenAddress, address _to, uint256 _amount) internal {
        treasure.safeTokenTransfer(_tokenAddress, _to, _amount);
    }

    function _updateUserExtraRewardDebt(uint256 _pid, address _user, uint256 _newAmount) internal {
        ExtraRewardInfo storage info;
        for (uint256 i = 0; i < extraRewardTokens.length; i ++) {
            info = extraRewardTokens[i];
            if (info.enabled) {
                poolUserRewardDebt[i][_pid][_user] = _newAmount.mul(poolAccTokenPerShare[i][_pid]).div(1e12);
            }
        }
    }

    function _updateExtraRewards(uint256 _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][msg.sender];

        ExtraRewardInfo storage info;
        uint256 pending;
        uint256 exRewardDebt;
        //        uint256 newDebt;
        for (uint256 i = 0; i < extraRewardTokens.length; i ++) {
            info = extraRewardTokens[i];
            if (info.enabled) {
                exRewardDebt = poolUserRewardDebt[i][_pid][_user];
                pending = user.amount.mul(poolAccTokenPerShare[i][_pid]).div(1e12).sub(exRewardDebt);
                if (pending > 0) {
                    safeExtraRewardTokenTransfer(info.token, msg.sender, pending);
                }
                /*newDebt = user.amount.mul(poolAccTokenPerShare[i][_pid]).div(1e12);
                if (newDebt != exRewardDebt) {
                    poolUserRewardDebt[i][_pid][_user] = newDebt;
                }*/
            }
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
