pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./ControllerRegistry.sol";


contract Accounts {
    using SafeMath for uint256;
    using ECDSA for bytes32;

    event SignUp(address indexed owner, bytes8 accountId);
    event TemporaryCreated(address indexed proxy, bytes32 indexed identityHash, bytes8 accountId);
    event Unlocked(bytes32 indexed identityHash, bytes8 indexed accountId, address newOwner);

    enum AccountStatus {
        NONE,
        TEMPORARY,
        CREATED
    }

    struct Account {
        address owner;
        AccountStatus status;

        address controller;
        address passwordProof;
    }

    mapping (bytes8 => Account) public accounts;
    mapping (address => bytes8) private passwordToAccount;
    mapping (address => bytes8) private addressToAccount;

    mapping (bytes32 => bytes8) public identityHashToAccount;

    uint256 public numberOfAccounts;

    ControllerRegistry private dataControllers;

    constructor(ControllerRegistry controllerReg) public {
        dataControllers = controllerReg;
    }

    modifier onlyDataController() {
        require(dataControllers.exists(msg.sender), "Accounts: caller is not a data controller");
        _;
    }

    function create() external returns (bytes8) {
        require(
            addressToAccount[msg.sender] == bytes8(0),
            "Accounts: you can make only one account per one Ethereum Account");

        bytes8 accountId = generateId(bytes32(0), msg.sender);
        accounts[accountId].owner = msg.sender;
        accounts[accountId].status = AccountStatus.CREATED;

        addressToAccount[msg.sender] = accountId;
        emit SignUp(msg.sender, accountId);
        return accountId;
    }

    function createTemporary(bytes32 identityHash)
        public
        onlyDataController
        returns (bytes8)
    {
        require(identityHashToAccount[identityHash] == bytes8(0), "Accounts: account already exists");

        bytes8 accountId = generateId(identityHash, msg.sender);
        accounts[accountId].controller = msg.sender;
        accounts[accountId].status = AccountStatus.TEMPORARY;

        identityHashToAccount[identityHash] = accountId;
        emit TemporaryCreated(msg.sender, identityHash, accountId);
        return accountId;
    }

    function unlockTemporary(bytes32 identityPreimage, address newOwner, bytes memory passwordSignature)
        public
        onlyDataController
    {
        // check that keccak256(identityPreimage) == account.identityHash
        bytes32 identityHash = keccak256(abi.encodePacked(identityPreimage));
        bytes8 accountId = identityHashToAccount[identityHash];

        require(isTemporary(accountId), "Accounts: it's not temporary account");
        Account storage account = accounts[accountId];

        require(
            msg.sender == account.controller,
            "Accounts: account must be unlocked through the designated data controller"
        );
        require(
            addressToAccount[newOwner] == bytes8(0),
            "Accounts: you can make only one account per one Ethereum Account"
        );
        account.owner = newOwner;
        addressToAccount[newOwner] = accountId;

        bytes memory message = abi.encodePacked(identityPreimage, newOwner);
        setPassword(accountId, message, passwordSignature);
        account.status = AccountStatus.CREATED;

        emit Unlocked(identityHash, accountId, newOwner);
    }

    function setController(address controller) external {
        // the controller and the proxy cannot modify controller.
        // a controller can be set only through the account owner's direct transaction.
        require(dataControllers.exists(controller), "Accounts: given address is not a data controller");
        require(addressToAccount[msg.sender] != bytes8(0), "Accounts: account does not exist");

        Account storage account = accounts[addressToAccount[msg.sender]];
        account.controller = controller;
    }

    function setPassword(bytes8 accountId, bytes memory message, bytes memory passwordSignature) internal {
        // user uses his/her own password to derive a sign key.
        // since ECRECOVER returns address (not public key itself),
        // we need to use address as a password proof.
        address passwordProof = keccak256(message).toEthSignedMessageHash().recover(passwordSignature);

        // password proof should be unique, since unique account ID is also used for key derivation
        require(passwordToAccount[passwordProof] == bytes8(0x0), "Accounts: password proof is not unique");

        accounts[accountId].passwordProof = passwordProof;
        passwordToAccount[passwordProof] = accountId;
    }

    function getAccount(bytes8 accountId) public view returns (Account memory) {
        require(exists(accountId), "Accounts: account does not exist");
        return accounts[accountId];
    }

    function getAccountByIdentityHash(bytes32 identityHash) public view returns (Account memory) {
        return getAccount(identityHashToAccount[identityHash]);
    }

    function getAccountId(address sender) public view returns (bytes8) {
        bytes8 accountId = addressToAccount[sender];
        require(accounts[accountId].status != AccountStatus.NONE, "Accounts: unknown address");
        return accountId;
    }

    function getAccountIdByIdentityHash(bytes32 identityHash) public view returns (bytes8) {
        return identityHashToAccount[identityHash];
    }

    function getAccountIdFromSignature(bytes32 messageHash, bytes memory signature) public view returns (bytes8) {
        address passwordProof = messageHash.toEthSignedMessageHash().recover(signature);
        bytes8 accountId = passwordToAccount[passwordProof];

        if (accounts[accountId].status == AccountStatus.NONE) {
            revert("Accounts: password mismatch");
        }
        return accountId;
    }

    function isTemporary(bytes8 accountId) public view returns (bool) {
        return accounts[accountId].status == AccountStatus.TEMPORARY;
    }

    function isControllerOf(address sender, bytes8 accountId) public view returns (bool) {
        return accounts[accountId].controller == sender;
    }

    function generateId(bytes32 uniqueData, address creator) internal view returns (bytes8) {
        bytes memory seed = abi.encodePacked(creator, block.number, uniqueData);
        return bytes8(keccak256(seed));
    }

    function exists(bytes8 accountId) public view returns (bool) {
        return accounts[accountId].status != AccountStatus.NONE;
    }
}
