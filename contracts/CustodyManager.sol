// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IFeePolicy.sol";
import "./IMintHook.sol";

/**
 * @dev Minimal token interface expected by this manager.
 */
interface ILeadBTCToken {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);

    function decimals() external view returns (uint8);
}

/**
 * @title CustodyManager (Escrow -> Off-chain Payout -> Finalize & Burn Total Spend)
 * @notice
 * Responsibilities:
 *  - Confirm BTC deposits and mint tokens (only on the designated mint chain).
 *  - Withdrawals:
 *      1) User escrows tokens in this contract (no burn yet); compute/store withdraw fee.
 *      2) Operator finalizes with real BTC spend (user receive + miner fee + operator fee);
 *         burn (user + miner + operator + stored withdrawFee) and refund any remainder.
 *  - Maintain a list of custody BTC addresses; ALL listed addresses are valid.
 */
contract CustodyManager is AccessControl, Pausable, ReentrancyGuard {
    // ------------------------ Roles ------------------------
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;   // governance / multisig
    bytes32 public constant OP_ROLE = keccak256("OP_ROLE"); // operators/robots
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE"); // pause
    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    // ------------------------ Dependencies ------------------------
    ILeadBTCToken public immutable token;
    IFeePolicy    public feePolicy;        // deposit & withdraw fee policy (optional)
    address       public feeRecipient;     // receiver for deposit mint fees (optional)

    // ------------------------ Optional Mint Hook -------------------
    /**
     * @dev If set, `confirmDeposit` will call `IMintHook.checkDeposit(...)` before minting.
     *      Implementers can encode Proof-of-Reserve (PoR) or any additional policy checks here.
     *      Set to address(0) to disable hook checks.
     */
    IMintHook public mintHook;

    // ------------------------ Deposit Dedup ------------------------
    mapping(bytes32 => bool) public usedDepositIds; // BTC txid or internal id

    // ------------------------ Custody BTC Address Book ------------------------
    string[] public custodyAddresses;

    // ------------------------ Withdrawals------------------------
    struct Withdrawal {
        address account;         // EVM requester
        string btcAddress;      // BTC destination
        uint256 amountGross;     // tokens escrowed by user
        uint256 withdrawFeeSats; // expected withdraw fee (policy-based; burned at finalize)
        bool processed;       // finalized or cancelled
        bool locked;      // NEW: set true when operator starts off-chain payout
        uint256 burned;          // actually burned total (user + miner + operator + withdrawFee)
        bytes32 btcTxId;         // off-chain payout txid (operator-filled)
        uint256 btcVout;         // off-chain payout vout (operator-filled)
    }

    uint64 public nextWithdrawalId = 1;
    mapping(uint64 => Withdrawal) public withdrawals;

    // ------------------------ Events ------------------------
    event DepositConfirmed(
        address indexed recipient,
        bytes32 indexed depositId,
        bytes32 indexed depositTxid,
        uint256 depositVout,
        uint256 depositSats,
        uint256 netSatsAfterFee
    );

    event WithdrawalInitiated(
        uint64  indexed id,
        address indexed requester,
        string  btcAddress,
        uint256 amountGross,
        uint256 expectedWithdrawFeeSats
    );

    event WithdrawalFinalized(
        uint64  indexed id,
        uint256 userReceiveSats,
        uint256 minerFeeSats,
        uint256 operatorFeeSats,
        uint256 withdrawFeeSats,
        uint256 spendTotalSats,
        uint256 burnedSats,
        bytes32 btcTxId,
        uint256 vout
    );

    event WithdrawalLocked(uint64 indexed id);
    event WithdrawalUnlocked(uint64 indexed id);

    event WithdrawalCancelled(uint64 indexed id, address indexed requester, uint256 refunded);

    event CustodyAddressAdded(uint256 indexed index, string btcAddress);
    event CustodyAddressRemoved(uint256 indexed index, string btcAddress);

    event FeePolicyChanged(address indexed oldPolicy, address indexed newPolicy);
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

    event MintHookChanged(address indexed oldHook, address indexed newHook);

    // ------------------------ Constructor ------------------------
    constructor(
        address token_,
        address admin_,
        address feeRecipient_,
        address feePolicy_
    ) {
        require(token_ != address(0), "token required");
        require(admin_ != address(0), "admin required");

        token = ILeadBTCToken(token_);
        require(ILeadBTCToken(token_).decimals() == 8, "token decimals != 8");
        feeRecipient = feeRecipient_;
        feePolicy = IFeePolicy(feePolicy_);

        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OP_ROLE, admin_);
        _grantRole(PAUSE_ROLE, admin_);

    }

    // ------------------------ Admin Params ------------------------
    function setFeeRecipient(address r) external onlyRole(ADMIN_ROLE) {
        emit FeeRecipientChanged(feeRecipient, r);
        feeRecipient = r;
    }

    function setFeePolicy(address p) external onlyRole(ADMIN_ROLE) {
        emit FeePolicyChanged(address(feePolicy), p);
        feePolicy = IFeePolicy(p);
    }

    /**
     * @notice Set or replace the external mint hook contract.
     * @dev Use address(0) to disable hook checks.
     */
    function setMintHook(address h) external onlyRole(ADMIN_ROLE) {
        emit MintHookChanged(address(mintHook), h);
        mintHook = IMintHook(h);
    }

    function pause() external onlyRole(PAUSE_ROLE) {_pause();}

    function unpause() external onlyRole(ADMIN_ROLE) {_unpause();}

    // ------------------------ Custody BTC Address Management ------------------------
    /**
     * @dev Append a custody BTC address. ALL addresses in the list are valid for custody.
     */
    function addCustodyAddress(string calldata btcAddr) external onlyRole(OP_ROLE) {
        require(bytes(btcAddr).length >= 8, "bad btc addr");
        custodyAddresses.push(btcAddr);
        emit CustodyAddressAdded(custodyAddresses.length - 1, btcAddr);
    }

    function removeCustodyAddress(uint256 index) external onlyRole(OP_ROLE) {
        uint256 len = custodyAddresses.length;
        require(index < len, "index oob");

        string memory removed = custodyAddresses[index];

        // swap-and-pop
        if (index != len - 1) {
            custodyAddresses[index] = custodyAddresses[len - 1];
        }
        custodyAddresses.pop();

        emit CustodyAddressRemoved(index, removed);
    }

    function custodyAddressesCount() external view returns (uint256) {
        return custodyAddresses.length;
    }

    // ------------------------ Deposit Confirmation -> Mint ------------------------
    function confirmDeposit(bytes32 txid, uint256 vout, address recipient, uint256 amountSats)
    external
    whenNotPaused
    nonReentrant
    onlyRole(DEPOSIT_ROLE)
    {
        require(recipient != address(0) && amountSats > 0, "bad params");
        bytes32 depositId = keccak256(abi.encode(txid, vout));
        if (address(mintHook) != address(0)) {
            bool ok = mintHook.checkDeposit(depositId, txid, vout, recipient, amountSats);
            require(ok, "mint hook rejected");
        }
        require(!usedDepositIds[depositId], "deposit used");
        usedDepositIds[depositId] = true;

        uint256 fee = address(feePolicy) == address(0) ? 0 : feePolicy.mintFee(recipient, amountSats);
        require(fee <= amountSats, "mint fee > amount");
        if (fee > 0) {
            require(feeRecipient != address(0), "feeRecipient not set");
            token.mint(feeRecipient, fee);
        }
        uint256 net = amountSats - fee;
        token.mint(recipient, net);

        emit DepositConfirmed(recipient, depositId, txid, vout, amountSats, net);
    }

    // ------------------------ Withdrawals ------------------------
    /**
     * @notice User initiates a withdrawal:
     *  - User approves this contract for `amountSats`.
     *  - Contract escrows tokens.
     *  - Expected withdrawFee (policy) is computed and stored; no burning yet.
     */
    function initiateWithdrawal(uint256 amountSats, string calldata btcAddress)
    external
    nonReentrant
    whenNotPaused
    returns (uint64 id)
    {
        require(amountSats > 0, "amount=0");
        require(bytes(btcAddress).length >= 8, "bad btc addr");

        require(token.transferFrom(msg.sender, address(this), amountSats), "transferFrom failed");

        uint256 wFee = address(feePolicy) == address(0) ? 0 : feePolicy.withdrawFee(msg.sender, amountSats);
        require(wFee <= amountSats, "withdrawFee > amount");

        id = nextWithdrawalId++;
        withdrawals[id] = Withdrawal({
            account: msg.sender,
            btcAddress: btcAddress,
            amountGross: amountSats,
            withdrawFeeSats: wFee,
            processed: false,
            locked: false,
            burned: 0,
            btcTxId: bytes32(0),
            btcVout: 0
        });

        emit WithdrawalInitiated(id, msg.sender, btcAddress, amountSats, wFee);
    }

    /**
     * @notice Mark a withdrawal as "in-flight" to prevent user cancellation.
     *         Call this on-chain first, then broadcast the BTC payout off-chain,
     *         and finally call `finalizeWithdrawal`.
     */
    function lockWithdrawal(uint64 id)
    external
    nonReentrant
    whenNotPaused
    onlyRole(WITHDRAW_ROLE)
    {
        Withdrawal storage w = withdrawals[id];
        require(!w.processed, "already processed");
        require(!w.locked, "already locked");
        w.locked = true;
        emit WithdrawalLocked(id);
    }

    /**
     * @notice Batch variant of {lockWithdrawal} for gas/nonce efficiency.
     */
    function lockWithdrawalBatch(uint64[] calldata ids)
    external
    nonReentrant
    whenNotPaused
    onlyRole(WITHDRAW_ROLE)
    {
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            uint64 id = ids[i];
            Withdrawal storage w = withdrawals[id];
            if (!w.processed && !w.locked) {
                w.locked = true;
                emit WithdrawalLocked(id);
            }
        }
    }

    /**
     * @notice Operational escape hatch: unlock a not-yet-processed withdrawal, allowing cancellation or retry.
     */
    function unlockWithdrawal(uint64 id)
    external
    nonReentrant
    whenNotPaused
    onlyRole(WITHDRAW_ROLE)
    {
        Withdrawal storage w = withdrawals[id];
        require(!w.processed, "already processed");
        require(w.locked, "not locked");
        w.locked = false;
        emit WithdrawalUnlocked(id);
    }

    /**
     * @notice Operator finalizes a withdrawal with real BTC spend numbers.
     *         NEW POLICY: Always burn the entire escrowed amount (`amountGross`) and never refund.
     *
     * @dev PoR/accounting reference:
     *      spendTotalSats = userReceive + minerFee + operatorFee
     *      burnedSats     = amountGross (full escrow burned)
     *      The off-chain delta is inferred as (burnedSats - spendTotalSats) and may be +/-.
     *      Overspend is allowed; operator bears the difference; no token mint/transfer here.
     */
    function finalizeWithdrawal(
        uint64 id,
        uint256 userReceiveSats,
        uint256 minerFeeSats,
        uint256 operatorFeeSats,
        bytes32 btcTxId,
        uint256 vout
    )
    external
    nonReentrant
    onlyRole(WITHDRAW_ROLE)
    {
        Withdrawal storage w = withdrawals[id];
        require(!w.processed, "already processed");
        require(w.locked, "not locked"); // must be locked before finalize
        require(btcTxId != bytes32(0), "btcTxId=0"); // must record a non-zero off-chain txid

        // Compute real total spend (allowed to exceed amountGross).
        uint256 spendTotal = userReceiveSats + minerFeeSats + operatorFeeSats;

        // Always burn the full escrow amount; no refund to the user.
        uint256 burned = w.amountGross;
        if (burned > 0) {
            token.burn(address(this), burned);
            w.burned = burned;
        }

        w.processed = true;
        w.btcTxId = btcTxId;
        w.btcVout = vout;

        emit WithdrawalFinalized(
            id,
            userReceiveSats,
            minerFeeSats,
            operatorFeeSats,
            w.withdrawFeeSats,
            spendTotal,
            burned,
            btcTxId,
            vout
        );
    }

    /**
     * @notice User can cancel a withdrawal before finalization and get all escrowed tokens back.
     *         Cancelling does not burn withdrawFee; everything is refunded.
     */
    function cancelWithdrawal(uint64 id)
    external
    nonReentrant
    {
        Withdrawal storage w = withdrawals[id];
        require(!w.processed, "processed");
        require(msg.sender == w.account, "not requester");
        require(!w.locked, "in-flight"); // cannot cancel once operator locks

        w.processed = true; // mark as handled (cancelled)
        uint256 refund = w.amountGross;
        w.amountGross = 0;

        require(token.transfer(msg.sender, refund), "refund failed");
        emit WithdrawalCancelled(id, msg.sender, refund);
    }

    function rescueERC20(address t, uint256 amt, address to) external onlyRole(ADMIN_ROLE) {
        require(to != address(0), "bad to");
        require(t != address(token), "no");
        (bool ok, bytes memory data) = t.call(abi.encodeWithSignature("transfer(address,uint256)", to, amt));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

// ------------------------ Read Helpers (for off-chain robots) ------------------------

    /// @notice True if locked and not processed yet.
    function isWithdrawalLocked(uint64 id) public view returns (bool) {
        Withdrawal storage w = withdrawals[id];
        return (w.locked && !w.processed);
    }

    /// @notice Alias kept for compatibility with off-chain scripts.
    function lockedWithdrawals(uint64 id) external view returns (bool) {
        return isWithdrawalLocked(id);
    }

    /// @notice True if finalized or cancelled.
    function isWithdrawalProcessed(uint64 id) external view returns (bool) {
        return withdrawals[id].processed;
    }

    /// @notice Convenience getter for dashboards/off-chain tools.
    function getWithdrawal(uint64 id)
    external
    view
    returns (
        address account,
        string memory btcAddress,
        uint256 amountGross,
        uint256 withdrawFeeSats,
        bool processed,
        bool locked,
        uint256 burned,
        bytes32 btcTxId,
        uint256 btcVout
    )
    {
        Withdrawal storage w = withdrawals[id];
        return (
            w.account,
            w.btcAddress,
            w.amountGross,
            w.withdrawFeeSats,
            w.processed,
            w.locked,
            w.burned,
            w.btcTxId,
            w.btcVout
        );
    }

    function custodyAddressesLength() public view returns (uint256) {
        return custodyAddresses.length;
    }

    function getCustodyAddresses() external view returns (string[] memory) {
        return custodyAddresses;
    }
}
