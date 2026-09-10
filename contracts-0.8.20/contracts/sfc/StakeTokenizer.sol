pragma solidity ^0.8.0;

import "./SFC.sol";
import "../common/Initializable.sol";

contract Spacer {
    address private _owner;
}

contract StakeTokenizer is Spacer, Initializable {
    SFC internal sfc;

    mapping(address => mapping(uint256 => uint256)) public outstandingSNEC;

    address public sNECTokenAddress;

    function initialize(address _sfc, address _sNECTokenAddress) public initializer {
        sfc = SFC(_sfc);
        sNECTokenAddress = _sNECTokenAddress;
    }

    function allowedToWithdrawStake(address sender, uint256 validatorID) public view returns(bool) {
        return outstandingSNEC[sender][validatorID] == 0;
    }
}
