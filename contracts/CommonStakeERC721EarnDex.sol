// SPDX-License-Identifier: MIT

pragma solidity =0.6.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC721/ERC721Holder.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/utils/EnumerableSet.sol';

import './ICommonStakeERC721EarnDex.sol';
import './ICommonMaster.sol';
import './IGetStakingPower.sol';

contract CommonStakeERC721EarnDex is ICommonStakeERC721EarnDex, ERC20, Ownable, ERC721Holder, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Address for address;
    using EnumerableSet for EnumerableSet.UintSet;

    // Info of each user.
    struct UserInfo {
        uint256 stakingPower;
        uint256 rewardDebt;
    }

    uint256 accDexPerShare; // Accumulated BAKEs per share, times 1e12. See below.
    uint256 public constant accDexPerShareMultiple = 1E20;
    uint256 public lastRewardBlock;
    // total has stake to DexryMaster stakingPower
    uint256 public totalStakingPower;
    IERC721 public immutable erc721;
    address public constant DexToken = 0xE02dF9e3e622DeBdD69fb838bB799E3F168902c5;
    ICommonMaster public immutable DexMaster;
    IGetStakingPower public immutable getStakingPowerProxy;
    bool public immutable isMintPowerTokenEveryTimes;
    mapping(uint256 => bool) private _mintPowers;
    mapping(address => UserInfo) private _userInfoMap;
    mapping(address => EnumerableSet.UintSet) private _stakingTokens;

    constructor(
        string memory _name,
        string memory _symbol,
        address _DexMaster,
        address _erc721,
        address _getStakingPower,
        bool _isMintPowerTokenEveryTimes
    ) public ERC20(_name, _symbol) {
        DexMaster = ICommonMaster(_DexMaster);
        erc721 = IERC721(_erc721);
        getStakingPowerProxy = IGetStakingPower(_getStakingPower);
        isMintPowerTokenEveryTimes = _isMintPowerTokenEveryTimes;
    }

    function getStakingPower(uint256 _tokenId) public view override returns (uint256) {
        return getStakingPowerProxy.getStakingPower(address(erc721), _tokenId);
    }

    // View function to see pending BAKEs on frontend.
    function pendingDex(address _user) external view override returns (uint256) {
        UserInfo memory userInfo = _userInfoMap[_user];
        uint256 _accDexPerShare = accDexPerShare;
        if (totalStakingPower != 0) {
            uint256 totalPendingDex = DexMaster.pendingToken(address(this), address(this));
            _accDexPerShare = _accDexPerShare.add(
                totalPendingDex.mul(accDexPerShareMultiple).div(totalStakingPower)
            );
        }
        return userInfo.stakingPower.mul(_accDexPerShare).div(accDexPerShareMultiple).sub(userInfo.rewardDebt);
    }

    function updateStaking() public override {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (totalStakingPower == 0) {
            lastRewardBlock = block.number;
            return;
        }
        (, uint256 lastRewardDebt) = DexMaster.poolUserInfoMap(address(this), address(this));
        DexMaster.stake(address(this), 0);
        (, uint256 newRewardDebt) = DexMaster.poolUserInfoMap(address(this), address(this));
        accDexPerShare = accDexPerShare.add(
            newRewardDebt.sub(lastRewardDebt).mul(accDexPerShareMultiple).div(totalStakingPower)
        );
        lastRewardBlock = block.number;
    }

    function _harvest(UserInfo storage userInfo) internal {
        updateStaking();
        if (userInfo.stakingPower != 0) {
            uint256 pending = userInfo.stakingPower.mul(accDexPerShare).div(accDexPerShareMultiple).sub(
                userInfo.rewardDebt
            );
            if (pending != 0) {
                safeDexTransfer(_msgSender(), pending);
                emit Harvest(_msgSender(), pending);
            }
        }
    }

    function harvest() external override {
        UserInfo storage userInfo = _userInfoMap[_msgSender()];
        _harvest(userInfo);
        userInfo.rewardDebt = userInfo.stakingPower.mul(accDexPerShare).div(accDexPerShareMultiple);
    }

    function stake(uint256 _tokenId) public override whenNotPaused {
        UserInfo storage userInfo = _userInfoMap[_msgSender()];
        _harvest(userInfo);
        uint256 stakingPower = getStakingPower(_tokenId);
        if (isMintPowerTokenEveryTimes || !_mintPowers[_tokenId]) {
            _mint(address(this), stakingPower);
            _mintPowers[_tokenId] = true;
        }

        erc721.safeTransferFrom(_msgSender(), address(this), _tokenId);
        userInfo.stakingPower = userInfo.stakingPower.add(stakingPower);
        _stakingTokens[_msgSender()].add(_tokenId);
        _approveToMasterIfNecessary(stakingPower);
        DexMaster.stake(address(this), stakingPower);
        totalStakingPower = totalStakingPower.add(stakingPower);
        userInfo.rewardDebt = userInfo.stakingPower.mul(accDexPerShare).div(accDexPerShareMultiple);
        emit Stake(_msgSender(), _tokenId, stakingPower);
    }

    function batchStake(uint256[] calldata _tokenIds) external override whenNotPaused {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            stake(_tokenIds[i]);
        }
    }

    function unstake(uint256 _tokenId) public override {
        require(_stakingTokens[_msgSender()].contains(_tokenId), 'UNSTAKE FORBIDDEN');
        UserInfo storage userInfo = _userInfoMap[_msgSender()];
        _harvest(userInfo);
        uint256 stakingPower = getStakingPower(_tokenId);
        userInfo.stakingPower = userInfo.stakingPower.sub(stakingPower);
        _stakingTokens[_msgSender()].remove(_tokenId);
        erc721.safeTransferFrom(address(this), _msgSender(), _tokenId);
        DexMaster.unstake(address(this), stakingPower);
        totalStakingPower = totalStakingPower.sub(stakingPower);
        userInfo.rewardDebt = userInfo.stakingPower.mul(accDexPerShare).div(accDexPerShareMultiple);
        if (isMintPowerTokenEveryTimes) {
            _burn(address(this), stakingPower);
        }
        emit Unstake(_msgSender(), _tokenId, stakingPower);
    }

    function batchUnstake(uint256[] calldata _tokenIds) external override {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            unstake(_tokenIds[i]);
        }
    }

    function unstakeAll() external override {
        EnumerableSet.UintSet storage stakingTokens = _stakingTokens[_msgSender()];
        uint256 length = stakingTokens.length();
        for (uint256 i = 0; i < length; ++i) {
            unstake(stakingTokens.at(0));
        }
    }

    function _approveToMasterIfNecessary(uint256 amount) internal {
        uint256 currentAllowance = allowance(address(this), address(DexMaster));
        if (currentAllowance < amount) {
            _approve(address(this), address(DexMaster), 2**256 - 1 - currentAllowance);
        }
    }

    function pauseStake() external override onlyOwner whenNotPaused {
        _pause();
    }

    function unpauseStake() external override onlyOwner whenPaused {
        _unpause();
    }

    function emergencyUnstake(uint256 _tokenId) external override {
        require(_stakingTokens[_msgSender()].contains(_tokenId), 'EMERGENCY UNSTAKE FORBIDDEN');
        UserInfo storage userInfo = _userInfoMap[_msgSender()];
        uint256 stakingPower = getStakingPower(_tokenId);
        userInfo.stakingPower = userInfo.stakingPower.sub(stakingPower);
        _stakingTokens[_msgSender()].remove(_tokenId);
        erc721.safeTransferFrom(address(this), _msgSender(), _tokenId);
        totalStakingPower = totalStakingPower.sub(stakingPower);
        userInfo.rewardDebt = userInfo.stakingPower.mul(accDexPerShare).div(accDexPerShareMultiple);
        emit EmergencyUnstake(_msgSender(), _tokenId, stakingPower);
    }

    function emergencyUnstakeAllFromDex(uint256 _amount) external override onlyOwner whenPaused {
        DexMaster.emergencyUnstake(address(this), _amount);
        emit EmergencyUnstakeAllFromDex(_msgSender(), _amount);
    }

    function safeDexTransfer(address _to, uint256 _amount) internal {
        uint256 bakeBal = IERC20(DexToken).balanceOf(address(this));
        if (_amount > bakeBal) {
            IERC20(DexToken).transfer(_to, bakeBal);
        } else {
            IERC20(DexToken).transfer(_to, _amount);
        }
    }

    function getUserInfo(address user)
        public
        view
        returns (
            uint256,
            uint256,
            uint256[] memory
        )
    {
        UserInfo memory userInfo = _userInfoMap[user];
        uint256[] memory tokenIds = new uint256[](_stakingTokens[user].length());
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            tokenIds[i] = _stakingTokens[user].at(i);
        }
        return (userInfo.stakingPower, userInfo.rewardDebt, tokenIds);
    }
}
