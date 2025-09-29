// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LeadBTC is OFT {

    error MinterNotAuthorized(address invalidMinter);
    error InvalidMinter(address invalidMinter);
    error BlackAccount(address account);

    event MinterChanged(address _oldMinter, address _minter);

    // Events for blacklist management
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    address public minter;

    // Blacklist mapping
    mapping(address => bool) private _blacklist;

    constructor(
        address _lzEndpoint,
        address _delegate
    ) OFT("Lead Wrapped Bitcoin", "leadBTC", _lzEndpoint, _delegate) Ownable(_delegate) {}

    function changeMinter(address _minter) public onlyOwner {
        if (_minter == address(0)) revert InvalidMinter(_minter);
        emit MinterChanged(minter, _minter);
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) {
            revert MinterNotAuthorized(msg.sender);
        }
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) {
            revert MinterNotAuthorized(msg.sender);
        }
        _burn(from, amount);
    }

    function decimals() override(ERC20) public view virtual returns (uint8) {
        return 8;
    }

    // Blacklist management
    function addToBlacklist(address account) public onlyOwner {
        _blacklist[account] = true;
        emit Blacklisted(account);
    }

    function removeFromBlacklist(address account) public onlyOwner {
        _blacklist[account] = false;
        emit UnBlacklisted(account);
    }

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklist[account];
    }

    function _checkPausedAndBlacklist(address account) internal view {
        require(!_blacklist[account], "account is blacklisted");
    }

    // -------- ERC20 hook (OZ v5) --------
    function _update(address from, address to, uint256 value) internal virtual override(ERC20) {
        if (from != address(0) && _blacklist[from]) revert BlackAccount(from);
        if (to != address(0) && _blacklist[to]) revert BlackAccount(to);
        super._update(from, to, value);
    }

}
