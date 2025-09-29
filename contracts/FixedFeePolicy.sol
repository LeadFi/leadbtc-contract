// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "./IFeePolicy.sol";

/**
 * @title FixedFeePolicy
 * @notice Simple constant-fee policy (token units, e.g., sats if token has 8 decimals).
 *         - mintFee:    fixed amount per deposit (clamped to amount)
 *         - withdrawFee: fixed amount per withdrawal (clamped to amount)
 */
contract FixedFeePolicy is IFeePolicy, AccessControl {
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /// @notice Fixed fees in token units (e.g., sats if decimals=8)
    uint256 public fixedMintFee;
    uint256 public fixedWithdrawFee;

    event MintFeeChanged(uint256 oldFee, uint256 newFee);
    event WithdrawFeeChanged(uint256 oldFee, uint256 newFee);

    constructor(address admin_, uint256 mintFee_, uint256 withdrawFee_) {
        require(admin_ != address(0), "admin required");
        _grantRole(ADMIN_ROLE, admin_);
        fixedMintFee = mintFee_;
        fixedWithdrawFee = withdrawFee_;
    }

    // -------- Admin --------
    function setMintFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        emit MintFeeChanged(fixedMintFee, newFee);
        fixedMintFee = newFee;
    }

    function setWithdrawFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        emit WithdrawFeeChanged(fixedWithdrawFee, newFee);
        fixedWithdrawFee = newFee;
    }

    // -------- IFeePolicy --------
    function mintFee(address /*to*/, uint256 amount) external view override returns (uint256) {
        // Clamp to avoid revert in CustodyManager when amount < fixedMintFee
        return fixedMintFee;
    }

    function withdrawFee(address /*from*/, uint256 amount) external view override returns (uint256) {
        // Clamp to avoid revert in CustodyManager when amount < fixedWithdrawFee
        return  fixedWithdrawFee;
    }
}
