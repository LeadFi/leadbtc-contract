// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IMintHook
 * @notice External hook to validate a BTC deposit before minting tokens.
 * @dev Return true (or revert) to approve the mint. Returning false will revert in the caller.
 *      Typical implementations may verify:
 *        - (txid, vout) exists in an on-chain allowlist or Merkle root
 *        - amount and recipient constraints
 *        - confirmations threshold and address ownership
 */
interface IMintHook {
    /**
     * @param depositId  keccak256(abi.encode(txid, vout))
     * @param txid       32-byte BTC txid (little-endian or chosen convention; must match hook’s stored data)
     * @param vout       Output index within the BTC transaction
     * @param recipient  EVM address that will receive minted tokens
     * @param amountSats Amount in satoshis that will be minted (before any mint fee)
     * @return ok        true to allow mint; false (or revert) to block
     */
    function checkDeposit(
        bytes32 depositId,
        bytes32 txid,
        uint256 vout,
        address recipient,
        uint256 amountSats
    ) external view returns (bool ok);
}
