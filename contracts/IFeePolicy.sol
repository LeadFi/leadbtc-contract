// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @dev Pluggable fee policy:
 * - mintFee: optional fee on deposits (mint side).
 * - withdrawFee: fee applied to the withdrawal amount (escrowed amount). This fee is NOT
 *   transferred as tokens; it is accounted and burned at finalize, keeping PoR exact.
 */
interface IFeePolicy {
    function mintFee(address to, uint256 amount) external view returns (uint256);

    function withdrawFee(address from, uint256 amount) external view returns (uint256);
}