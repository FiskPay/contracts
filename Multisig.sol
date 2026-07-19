//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

interface IERC20{

    function transfer(address to, uint256 amount) external returns(bool);
}

// Simple owner multisig wallet used as a safer Proxy owner.
// Any owner can submit a transaction, but execution needs enough owner approvals.
contract Multisig{

//-----------------------------------------------------------------------// v EVENTS

    // Emitted when an owner creates a transaction request.
    event TransactionSubmitted(uint256 indexed transactionId, address indexed creator, address indexed to, uint256 value, bytes data);
    // Emitted when an owner approves a transaction request.
    event TransactionApproved(uint256 indexed transactionId, address indexed owner);
    // Emitted when an owner removes their approval before execution.
    event TransactionRevoked(uint256 indexed transactionId, address indexed owner);
    // Emitted after an approved transaction is executed.
    event TransactionExecuted(uint256 indexed transactionId, address indexed executor);
    // Emitted when an owner is added through the multisig.
    event OwnerAdded(address indexed owner);
    // Emitted when an owner is removed through the multisig.
    event OwnerRemoved(address indexed owner);
    // Emitted when the automatic approval threshold changes after an owner change.
    event ThresholdSet(uint256 threshold);
    // Emitted when native POL is withdrawn from this contract.
    event PolWithdrawn(address indexed to, uint256 amount);
    // Emitted when ERC20 tokens are withdrawn from this contract.
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

//-----------------------------------------------------------------------// v BOOLEANS

    // Reentrancy lock used while executing external calls.
    bool private locked;

//-----------------------------------------------------------------------// v NUMBERS

    // Minimum number of owner approvals required before a transaction can execute. Must stay above 50%.
    uint256 public threshold;
    // Total number of submitted transactions. Also used as the next transaction id.
    uint256 public transactionCount;
    // Changes when owners or threshold change, so old pending approvals cannot be reused.
    uint32 public ownerVersion;

//-----------------------------------------------------------------------// v STRINGS

    // Human-readable contract name.
    string constant public Name = "Multisig";

//-----------------------------------------------------------------------// v ADDRESSES

    // Owner that created the transaction currently being executed.
    address private executingCreator;

//-----------------------------------------------------------------------// v STRUCTS

    struct Transaction{

        address creator;                // Owner that created the transaction.
        address to;                     // Contract or wallet that receives the call.
        uint256 value;                  // Native POL sent with the call.
        bytes data;                     // Encoded function call data.
        uint32 approvals;               // Number of current owner approvals.
        uint32 ownerVersion;            // Owner configuration version used when this transaction was created.
        bool executed;                  // Prevents executing the same transaction twice.
    }

//-----------------------------------------------------------------------// v MAPPINGS

    // Fast owner lookup for permission checks.
    mapping(address => bool) public isOwner;
    // Submitted transactions by id.
    mapping(uint256 => Transaction) public transactions;
    // Tracks whether an owner has approved a specific transaction id.
    mapping(uint256 => mapping(address => bool)) public approved;

//-----------------------------------------------------------------------// v ARRAYS

    // Owner list. Changes require an approved multisig self-call.
    address[] private owners;

//-----------------------------------------------------------------------// v ERRORS

    error OwnerOnly();
    error InvalidOwner();
    error InvalidThreshold();
    error InvalidTransaction();
    error AlreadyApproved();
    error NotApproved();
    error AlreadyExecuted();
    error InsufficientApprovals();
    error TransferFailed();
    error Reentrant();
    error MultisigOnly();
    error InvalidAmount();
    error InvalidToken();
    error StaleTransaction();

//-----------------------------------------------------------------------// v MODIFIERS

    modifier ownerOnly(){

        // Only configured owner wallets may submit, approve, revoke, or execute.
        if(!isOwner[msg.sender])
            revert OwnerOnly();
        _;
    }

    modifier nonReentrant(){

        // Prevents a called contract from entering ExecuteTransaction again mid-call.
        if(locked)
            revert Reentrant();

        locked = true;
        _;
        locked = false;
    }

    modifier multisigOnly(){

        // Sensitive helpers must be called by an approved transaction from this contract.
        if(msg.sender != address(this))
            revert MultisigOnly();
        _;
    }

//-----------------------------------------------------------------------// v CONSTRUCTOR

    constructor(address[] memory _owners){

        uint256 ownerCount = _owners.length;

        if(ownerCount < 2)
            revert InvalidOwner();

        for(uint256 i = 0; i < ownerCount; i++){

            address owner = _owners[i];

            _validateNewOwner(owner);

            isOwner[owner] = true;
            owners.push(owner);
        }

        threshold = _getThreshold(ownerCount);
    }

//-----------------------------------------------------------------------// v GET FUNCTIONS

    // Returns the fixed owner list.
    function GetOwners() public view returns(address[] memory){

        return owners;
    }

    // Returns the full transaction information for frontends/tools.
    function GetTransaction(uint256 _transactionId) public view returns(address creator, address to, uint256 value, bytes memory data, bool executed, uint256 approvals, uint256 version){

        Transaction storage transaction = transactions[_transactionId];

        return(transaction.creator, transaction.to, transaction.value, transaction.data, transaction.executed, transaction.approvals, transaction.ownerVersion);
    }

    // Returns the owners who already approved a transaction.
    function GetApprovedOwners(uint256 _transactionId) public view returns(address[] memory){

        Transaction storage transaction = transactions[_transactionId];

        if(transaction.to == address(0))
            revert InvalidTransaction();
        if(transaction.ownerVersion != ownerVersion)
            revert StaleTransaction();

        uint256 ownerCount = owners.length;
        uint256 approvalCount = transaction.approvals;
        address[] memory approvedOwners = new address[](approvalCount);
        uint256 index = 0;

        for(uint256 i = 0; i < ownerCount; i++){

            address owner = owners[i];

            if(approved[_transactionId][owner]){

                approvedOwners[index] = owner;
                index++;
            }
        }

        return approvedOwners;
    }

    // Returns unexecuted transaction ids inside a scanned id range.
    function GetPendingTransactions(uint256 _from, uint256 _count) public view returns(uint256[] memory){

        uint256 txCount = transactionCount;

        if(_from >= txCount || _count == 0)
            return new uint256[](0);

        uint256 remaining = txCount - _from;
        uint256 scanCount = _count;

        if(scanCount > remaining)
            scanCount = remaining;

        uint256 end = _from + scanCount;
        uint256 pendingCount = 0;

        for(uint256 i = _from; i < end; i++){

            if(!transactions[i].executed && transactions[i].ownerVersion == ownerVersion)
                pendingCount++;
        }

        uint256[] memory pendingTransactions = new uint256[](pendingCount);
        uint256 index = 0;

        for(uint256 i = _from; i < end; i++){

            if(!transactions[i].executed && transactions[i].ownerVersion == ownerVersion){

                pendingTransactions[index] = i;
                index++;
            }
        }

        return pendingTransactions;
    }

//-----------------------------------------------------------------------// v SET FUNCTIONS

    // Creates a transaction and automatically approves it by the creator.
    function SubmitTransaction(address _to, uint256 _value, bytes calldata _data) public ownerOnly returns(uint256){

        // A transaction must have a real target address.
        if(_to == address(0))
            revert InvalidTransaction();

        // Use the current counter as the id, then reserve the next id.
        uint256 transactionId = transactionCount;
        transactionCount++;

        // Store the requested call. Approval count starts at zero and is added below.
        transactions[transactionId] = Transaction(msg.sender, _to, _value, _data, 0, ownerVersion, false);

        emit TransactionSubmitted(transactionId, msg.sender, _to, _value, _data);

        // The submitting owner also counts as the first approver.
        ApproveTransaction(transactionId);

        return transactionId;
    }

    // Adds the caller's approval to a pending transaction.
    function ApproveTransaction(uint256 _transactionId) public ownerOnly returns(bool){

        Transaction storage transaction = transactions[_transactionId];

        // Missing transactions have an empty target address.
        if(transaction.to == address(0))
            revert InvalidTransaction();
        if(transaction.ownerVersion != ownerVersion)
            revert StaleTransaction();
        // Executed transactions cannot be changed.
        if(transaction.executed)
            revert AlreadyExecuted();
        // Each owner can approve a transaction only once.
        if(approved[_transactionId][msg.sender])
            revert AlreadyApproved();

        approved[_transactionId][msg.sender] = true;
        transaction.approvals++;

        emit TransactionApproved(_transactionId, msg.sender);

        return true;
    }

    // Removes the caller's approval from a pending transaction.
    function RevokeApproval(uint256 _transactionId) public ownerOnly returns(bool){

        Transaction storage transaction = transactions[_transactionId];

        // Missing transactions have an empty target address.
        if(transaction.to == address(0))
            revert InvalidTransaction();
        if(transaction.ownerVersion != ownerVersion)
            revert StaleTransaction();
        // Executed transactions are final.
        if(transaction.executed)
            revert AlreadyExecuted();
        // Only an owner who approved can revoke their approval.
        if(!approved[_transactionId][msg.sender])
            revert NotApproved();

        approved[_transactionId][msg.sender] = false;
        transaction.approvals--;

        emit TransactionRevoked(_transactionId, msg.sender);

        return true;
    }

    // Executes an approved transaction. The caller must be an owner, but does not need to be the creator.
    function ExecuteTransaction(uint256 _transactionId) public ownerOnly nonReentrant returns(bytes memory){

        Transaction storage transaction = transactions[_transactionId];

        // Missing transactions have an empty target address.
        if(transaction.to == address(0))
            revert InvalidTransaction();
        if(transaction.ownerVersion != ownerVersion)
            revert StaleTransaction();
        // Prevent double execution of the same approved call.
        if(transaction.executed)
            revert AlreadyExecuted();
        // The transaction can execute only after enough owners approve it.
        if(transaction.approvals < threshold)
            revert InsufficientApprovals();

        // Mark executed before the external call to prevent reentrant double-spend attempts.
        transaction.executed = true;
        // Save the creator so self-call helpers can pay the owner that created the transaction.
        executingCreator = transaction.creator;

        // Execute the requested call. Data may be empty for plain POL transfers.
        (bool ok, bytes memory result) = transaction.to.call{value : transaction.value}(transaction.data);
        executingCreator = address(0);

        if(!ok)
            revert TransferFailed();

        emit TransactionExecuted(_transactionId, msg.sender);

        return result;
    }

    // Adds a new wallet owner and recalculates the strict-majority threshold.
    function AddOwner(address _owner) public multisigOnly returns(bool){

        _validateNewOwner(_owner);

        isOwner[_owner] = true;
        owners.push(_owner);
        threshold = _getThreshold(owners.length);
        ownerVersion++;

        emit OwnerAdded(_owner);
        emit ThresholdSet(threshold);

        return true;
    }

    // Removes an owner and recalculates the strict-majority threshold.
    function RemoveOwner(address _owner) public multisigOnly returns(bool){

        uint256 ownerCount = owners.length;
        uint256 newOwnerCount = ownerCount - 1;

        if(!isOwner[_owner] || newOwnerCount < 2)
            revert InvalidOwner();

        isOwner[_owner] = false;

        for(uint256 i = 0; i < ownerCount; i++){

            if(owners[i] == _owner){

                owners[i] = owners[newOwnerCount];
                owners.pop();
                break;
            }
        }

        ownerVersion++;
        threshold = _getThreshold(newOwnerCount);

        emit OwnerRemoved(_owner);
        emit ThresholdSet(threshold);

        return true;
    }

    // Withdraws native POL to the owner that created the approved transaction.
    function WithdrawPolToCaller(uint256 _amount) public multisigOnly returns(bool){

        address to = executingCreator;

        if(to == address(0) || _amount == 0)
            revert InvalidAmount();

        _transferPol(to, _amount);

        emit PolWithdrawn(to, _amount);

        return true;
    }

    // Splits native POL equally across all configured owners.
    function WithdrawPolToOwners(uint256 _amount) public multisigOnly returns(bool){

        uint256 ownerCount = owners.length;

        if(_amount == 0)
            revert InvalidAmount();

        // Any remainder stays in this contract instead of being split.
        uint256 share = _amount / ownerCount;

        if(share == 0)
            revert InvalidAmount();

        for(uint256 i = 0; i < ownerCount; i++){

            address to = owners[i];

            _transferPol(to, share);

            emit PolWithdrawn(to, share);
        }

        return true;
    }

    // Withdraws ERC20 tokens to the owner that created the approved transaction.
    function WithdrawTokenToCaller(address _token, uint256 _amount) public multisigOnly returns(bool){

        address to = executingCreator;

        if(_token == address(0) || to == address(0) || _amount == 0)
            revert InvalidAmount();

        _transferToken(_token, to, _amount);

        emit TokenWithdrawn(_token, to, _amount);

        return true;
    }

    // Splits ERC20 tokens equally across all configured owners.
    function WithdrawTokenToOwners(address _token, uint256 _amount) public multisigOnly returns(bool){

        uint256 ownerCount = owners.length;

        if(_token == address(0) || _amount == 0)
            revert InvalidAmount();

        // Any remainder stays in this contract instead of being split.
        uint256 share = _amount / ownerCount;

        if(share == 0)
            revert InvalidAmount();

        for(uint256 i = 0; i < ownerCount; i++){

            address to = owners[i];

            _transferToken(_token, to, share);

            emit TokenWithdrawn(_token, to, share);
        }

        return true;
    }

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

    // Sends native POL and reverts if the receiver rejects the transfer.
    function _transferPol(address _to, uint256 _amount) private{

        (bool ok,) = payable(_to).call{value : _amount}("");

        if(!ok)
            revert TransferFailed();
    }

    // Checks that a new owner is a unique normal wallet address.
    function _validateNewOwner(address _owner) private view{

        if(_owner == address(0) || isOwner[_owner])
            revert InvalidOwner();
        if(_owner.code.length != 0)
            revert InvalidOwner();
    }

    // Calculates the strict-majority threshold for the current owner count.
    function _getThreshold(uint256 _ownerCount) private pure returns(uint256){

        if(_ownerCount < 2)
            revert InvalidThreshold();

        return(_ownerCount / 2 + 1);
    }

    // Sends ERC20 tokens and supports tokens that either return true or return no value.
    function _transferToken(address _token, address _to, uint256 _amount) private{

        if(_token.code.length == 0)
            revert InvalidToken();

        (bool ok, bytes memory data) = _token.call(abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount));

        if(!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

//-----------------------------------------------------------------------// v DEFAULTS

    // Allows this multisig to receive native POL fees.
    receive() external payable{}

    // Allows this multisig to receive POL with unknown calldata.
    fallback() external payable{}
}
