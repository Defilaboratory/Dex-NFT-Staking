// SPDX-License-Identifier: MIT

pragma solidity =0.6.6;

import '@openzeppelin/contracts/access/Ownable.sol';
import './CommonStakeERC721EarnDex.sol';

contract CommonStakeERC721EarnDexFactory is Ownable {
    event CommonStakeERC721EarnDexCreated(address indexed commonMaster);

    constructor() public {}

    function createCommonStakeERC721EarnDex(
        string calldata _name,
        string calldata _symbol,
        address _DexMaster,
        address _erc721,
        address _getStakingPower,
        bool _isMintPowerTokenEveryTimes
    ) external onlyOwner returns (address) {
        CommonStakeERC721EarnDex commonMaster = new CommonStakeERC721EarnDex(
            _name,
            _symbol,
            _DexMaster,
            _erc721,
            _getStakingPower,
            _isMintPowerTokenEveryTimes
        );
        Ownable(address(commonMaster)).transferOwnership(_msgSender());
        emit CommonStakeERC721EarnDexCreated(address(commonMaster));
        return address(commonMaster);
    }
}
