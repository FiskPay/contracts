//SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

interface IGlobal{

    function Name() external pure returns(string memory);
}

contract Proxy{

//-----------------------------------------------------------------------// v EVENTS

//-----------------------------------------------------------------------// v INTERFACES

//-----------------------------------------------------------------------// v BOOLEANS

//-----------------------------------------------------------------------// v ADDRESSES

    address public Owner = msg.sender;
    address private newOwner = msg.sender;

//-----------------------------------------------------------------------// v NUMBERS

//-----------------------------------------------------------------------// v BYTES

//-----------------------------------------------------------------------// v STRINGS

//-----------------------------------------------------------------------// v STRUCTS

//-----------------------------------------------------------------------// v ENUMS

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(string => address) private nameToAddress;
    mapping(address => string) private addressToName;

//-----------------------------------------------------------------------// v MODIFIERS

    modifier ownerOnly{

        if(Owner != msg.sender)
            revert("Owner only");

        delete newOwner;
        _;
    }

//-----------------------------------------------------------------------// v CONSTRUCTOR

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

//-----------------------------------------------------------------------// v GET FUNCTIONS

    function GetContractAddress(string calldata _name) public view returns(address){

        return nameToAddress[_name];
    }

    function GetContractName(address _address) public view returns(string memory){

        return addressToName[_address];
    }

//-----------------------------------------------------------------------// v SET FUNTIONS

    function ChangeOwnership(address _newOwner) public ownerOnly returns(bool){

        newOwner = _newOwner;

        return(true);
    }

    function AcceptOwnership() public returns(bool){

        if(newOwner != msg.sender)
            revert("Can not accept");

        Owner = newOwner;
        delete newOwner;

        return(true);
    }
    //
    function AddContract(string calldata _name, address _address) public ownerOnly returns(bool){

        if(nameToAddress[_name] != address(0))
            revert("Name already used");
        else if(keccak256(abi.encodePacked(addressToName[_address])) != keccak256(abi.encodePacked("")))
            revert("Address already used");

        uint32 size;
        assembly{size := extcodesize(_address)}

        if(size == 0)
            revert("Not a contract");

        string memory name = IGlobal(_address).Name();

        if(keccak256(abi.encodePacked(_name)) != keccak256(abi.encodePacked(name)))
            revert("Names mismatch");

        nameToAddress[_name] = _address;
        addressToName[_address] = _name;

        return(true);
    }

    function UpdateContract(string calldata _name, address _address) public ownerOnly returns(bool){

        if(nameToAddress[_name] == address(0))
            revert("Name not used");
        else if(keccak256(abi.encodePacked(addressToName[_address])) != keccak256(abi.encodePacked("")))
            revert("Address already used");
        
        uint32 size;
        assembly{size := extcodesize(_address)}

        if(size == 0)
            revert("Not a contract");

        string memory name = IGlobal(_address).Name();

        if(keccak256(abi.encodePacked(_name)) != keccak256(abi.encodePacked(name)))
            revert("Names mismatch");

        delete addressToName[nameToAddress[_name]];

        nameToAddress[_name] = _address;
        addressToName[_address] = _name;

        return(true);
    }

    function RemoveContract(string calldata _name) public ownerOnly returns(bool){

        if(nameToAddress[_name] == address(0))
            revert("Name not used");
        
        delete addressToName[nameToAddress[_name]];
        delete nameToAddress[_name];

        return(true);
    }

//-----------------------------------------------------------------------// v DEFAULTS

    fallback() external{}
}