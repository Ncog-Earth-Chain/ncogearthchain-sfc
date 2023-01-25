pragma solidity ^0.5.0;

import "./SFC.sol";
import "../erc20/base/ERC20Burnable.sol";
import "../erc20/base/ERC20Mintable.sol";
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

    function mintSNEC(uint256 toValidatorID) external {
        address delegator = msg.sender;
        uint256 lockedStake = sfc.getLockedStake(delegator, toValidatorID);
        require(lockedStake > 0, "delegation isn't locked up");
        require(lockedStake > outstandingSNEC[delegator][toValidatorID], "sNEC is already minted");

        uint256 diff = lockedStake - outstandingSNEC[delegator][toValidatorID];
        outstandingSNEC[delegator][toValidatorID] = lockedStake;

        // It's important that we mint after updating outstandingSNEC (protection against Re-Entrancy)
        require(ERC20Mintable(sNECTokenAddress).mint(delegator, diff), "failed to mint sNEC");
    }

    function redeemSNEC(uint256 validatorID, uint256 amount) external {
        require(outstandingSNEC[msg.sender][validatorID] >= amount, "low outstanding sNEC balance");
        require(IERC20(sNECTokenAddress).allowance(msg.sender, address(this)) >= amount, "insufficient allowance");
        outstandingSNEC[msg.sender][validatorID] -= amount;

        // It's important that we burn after updating outstandingSNEC (protection against Re-Entrancy)
        ERC20Burnable(sNECTokenAddress).burnFrom(msg.sender, amount);
    }

    function allowedToWithdrawStake(address sender, uint256 validatorID) public view returns(bool) {
        return outstandingSNEC[sender][validatorID] == 0;
    }
}
