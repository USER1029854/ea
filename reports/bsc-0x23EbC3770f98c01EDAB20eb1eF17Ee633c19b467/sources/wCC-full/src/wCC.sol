// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.24;





/**
 * @title wCC (Wrapped Canton Coin)
 * @notice ERC20 token representing Canton Coin on EVM chains with LayerZero OFT support
 * @dev Implements dual functionality:
 *      1. Canton Bridge: Controlled mint/burn for CC ↔ wCC conversion
 *      2. LayerZero OFT: Permissionless cross-chain transfers between EVM chains
 */
contract wCC is OFT, AccessControl, Pausable {
    /// @notice Role identifier for minting tokens (Canton Bridge only)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    /// @notice Role identifier for burning tokens (Canton Bridge only)
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    /// @notice Role identifier for pausing token operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Emitted when tokens are minted through Canton Bridge
    event Minted(address indexed to, uint256 amount, string orderId);
    
    /// @notice Emitted when tokens are burned through Canton Bridge
    event Burned(address indexed from, uint256 amount, string orderId);

    /**
     * @notice Contract constructor
     * @param _lzEndpoint LayerZero endpoint address for this chain
     * @param _delegate Initial delegate address for LayerZero operations (also becomes owner)
     */
    constructor(
        address _lzEndpoint,
        address _delegate
    ) OFT("Wrapped Canton Coin", "wCC", _lzEndpoint, _delegate) Ownable(_delegate) {
        _grantRole(DEFAULT_ADMIN_ROLE, _delegate);
        _grantRole(PAUSER_ROLE, _delegate);
    }

    /**
     * @notice Mint tokens (Canton Bridge only)
     * @dev Only callable by addresses with MINTER_ROLE
     * @param to Recipient address
     * @param amount Amount of tokens to mint (in wei, 18 decimals)
     * @param orderId Canton Bridge order identifier for tracking
     */
    function mint(
        address to,
        uint256 amount,
        string calldata orderId
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(to != address(0), "wCC: mint to zero address");
        require(amount > 0, "wCC: mint amount must be positive");
        require(bytes(orderId).length > 0, "wCC: orderId cannot be empty");

        _mint(to, amount);
        emit Minted(to, amount, orderId);
    }

    /**
     * @notice Burn tokens (Canton Bridge only)
     * @dev Only callable by addresses with BURNER_ROLE
     *      Requires user to have approved sufficient allowance to the caller (BridgeController)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn (in wei, 18 decimals)
     * @param orderId Canton Bridge order identifier for tracking
     */
    function burn(
        address from,
        uint256 amount,
        string calldata orderId
    ) external onlyRole(BURNER_ROLE) whenNotPaused {
        require(from != address(0), "wCC: burn from zero address");
        require(amount > 0, "wCC: burn amount must be positive");
        require(bytes(orderId).length > 0, "wCC: orderId cannot be empty");

        // Check and consume allowance (follows ERC20 standard)
        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= amount, "wCC: burn amount exceeds allowance");
        
        // Decrease allowance
        _approve(from, msg.sender, currentAllowance - amount);

        _burn(from, amount);
        emit Burned(from, amount, orderId);
    }

    /**
     * @notice Pause all token operations
     * @dev Only callable by addresses with PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all token operations
     * @dev Only callable by addresses with PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Override _update to enforce pause state
     * @dev Called on all token transfers, mints, and burns
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._update(from, to, amount);
    }

    /**
     * @notice Check if contract supports interface
     * @dev Required for AccessControl and OFT compatibility
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
