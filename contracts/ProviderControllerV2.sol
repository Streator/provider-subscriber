// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";

contract ProviderController is Ownable {
    using BitMaps for BitMaps.BitMap;

    IERC20 token;

    enum Plan { basic, premium, vip }

    struct Provider {
        address owner;
        uint32 subscriberCount;
        uint32 lastUpdated; // last date when provider's balance has been updated
        uint256 fee; // fee is the cost in token units that the provider charges to subscribers per month
        uint256 balance; // the provider balance is stored in the contract.
    }

    struct Subscriber {
        address owner;
        Plan plan; // basic / premium / vip
        uint32 pausedDate; // date when subscription has been paused
        uint32 createdDate; // subscription start date
        uint256 balance; // the subscriber balance is stored in the contract
    }

    uint256 providersLength;
    uint64 providerId;
    uint64 subscriberId;
    mapping(uint64 => Provider) providers;
    mapping(uint64 => Subscriber) subscribers;
    mapping(uint64 => uint64[]) subscriberProviders;
    mapping(bytes => bool) registerKeys; // Track register keys

    BitMaps.BitMap private providersBitmap; // using OZ BitMap library for saving active flag to save gas
    uint256 private constant MIN_FEE = 100;
    uint32 private constant PAYMENT_FREQUENCY = 30 days;
    uint64 private constant MAX_NUMBER_PROVIDERS = 200;

    // Events
    event ProviderAdded(uint64 indexed providerId, address indexed owner, bytes publicKey, uint256 fee);
    event ProviderRemoved(uint64 indexed providerId);
    event SubscriberAdded(uint64 indexed subscriberId, address indexed owner, Plan plan, uint256 deposit);

    // Errors
    error FeeTooLow();
    error RegisterKeyAlreadyUsed();
    error MaxProvidersExceeded();
    error IsNotProviderOwner();
    error IsNotSubscriberOwner();
    error InvalidProviderId();
    error ProviderIsInactive();
    error InvalidProvidersNumber();
    error InsufficientDeposit();
    error WithdrawalNotAvailableYet();
    error ProviderDoesNotExist();
    error SubscriberDoesNotExist();

    constructor(address _token) {
        token = IERC20(_token);
    }

    function registerProvider(bytes calldata registerKey, uint256 fee) external returns (uint64 id) {
        // fee (token units) should be greater than a fixed value. Add a check
        if(fee < MIN_FEE)
            revert FeeTooLow();

        // the system doesn't allow to register a provider with the same registerKey.
        if(registerKeys[registerKey])
            revert RegisterKeyAlreadyUsed();

        registerKeys[registerKey] = true;

        // check MAX_NUMBER_PROVIDERS is not surpassed
        id = ++providerId;
        providersLength++;
        if(providersLength > MAX_NUMBER_PROVIDERS)
            revert MaxProvidersExceeded();
        
        providers[id] = Provider({owner: msg.sender, subscriberCount: 0, balance: 0, fee: fee, lastUpdated: uint32(block.timestamp)});
        providersBitmap.setTo(id, true);
        emit ProviderAdded(id, msg.sender, registerKey, fee);
    }

    function removeProvider(uint64 providerId) external onlyProviderOwner(providerId) {
        // Only the owner of the Provider can remove it

        Provider storage provider = providers[providerId];
        uint256 currentBalance = provider.balance + calculateProviderEarnings(providerId);

        providersLength--;
        delete providers[providerId];
        providersBitmap.setTo(providerId, false);
        emit ProviderRemoved(providerId);

        if (currentBalance > 0) {
            transferBalance(msg.sender, currentBalance);
        }
    }

    function withdrawProviderEarnings(uint64 providerId) public onlyProviderOwner(providerId) {
        // only the owner of the provider can withdraw funds
        Provider storage provider = providers[providerId];
        uint256 amount = provider.balance + calculateProviderEarnings(providerId);
        provider.balance = 0;
        provider.lastUpdated = uint32(block.timestamp);
        if(amount > 0)
            transferBalance(msg.sender, amount);
    }

    function updateProvidersState(uint64[] calldata providerIds, bool isActive) external onlyOwner {
        // Implement the logic of this function
        // It will receive a list of provider Ids and a flag (enable /disable)
        // and update the providers state accordingly (active / inactive)
        // You can change data structures if that helps improve gas cost
        // Remember the limt of providers in the system is 200
        // Only the owner of the contract can call this function

        for (uint i = 0; i < providerIds.length; i++) {
            if(providerIds[i] >= providerId) revert InvalidProviderId();
            providersBitmap.setTo(providerIds[i], isActive);

        }
    }

    // updates provider fee, updates provider's balance before
    function updateProviderFee(uint64 providerId, uint256 fee) external onlyProviderOwner(providerId) {
        updateProviderBalance(providerId);
        providers[providerId].fee = fee;
    }

    function resgisterSubscriber(uint256 deposit, Plan plan, uint64[] calldata providerIds) external {
        // Only allow subscriber registrations if providers are active
        // Provider list must at least 3 and less or equals 14
        if(providerIds.length < 3 || providerIds.length > 14) revert InvalidProvidersNumber();
        // plan does not affect the cost of the subscription

        uint64 id = ++subscriberId;
        uint256 totalFees;

        for (uint i = 0; i < providerIds.length; i++) {
            if(!isProviderActive(providerIds[i])) revert ProviderIsInactive();
            updateProviderBalance(providerIds[i]);
            providers[providerIds[i]].subscriberCount++;
            totalFees += providers[providerIds[i]].fee;
        }
        // check if the deposit amount cover expenses of providers' fees for at least 2 months
        if(deposit < totalFees * 2) revert InsufficientDeposit();

        subscribers[id] = Subscriber({owner: msg.sender, balance: deposit, plan: plan, pausedDate: 0, createdDate: uint32(block.timestamp)});

        for (uint i; i < providerIds.length; i++) {
            subscriberProviders[id].push(providerIds[i]);
        }
        // deposit the funds
        token.transferFrom(msg.sender, address(this), deposit);

        emit SubscriberAdded(id, msg.sender, plan, deposit);
    }

    function pauseSubscription(uint64 subscriberId) external {
        // Only the subscriber owner can pause the subscription
        subscribers[subscriberId].pausedDate = uint32(block.timestamp);

        // when the subscription is paused, it must be removed from providers list (providerSubscribers)
        // and for every provider, reduce subscriberCount

        // when pausing a subscription, the funds of the subscriber are not transferred back to the owner
        uint64[] memory providerIds = subscriberProviders[subscriberId]; 
        
        for (uint i; i < providerIds.length; i++) {
            uint64 providerId = providerIds[i];
            if(!isProviderActive(providerId)) continue;
            updateProviderBalance(providerId);
            providers[providerIds[i]].subscriberCount--;
        }
    }

    function deposit(uint64 subscriberId, uint256 deposit) external onlySubscriberOwner(subscriberId) {
        // Only the subscriber owner can deposit to the subscription

        token.transferFrom(msg.sender, address(this), deposit);
        subscribers[subscriberId].balance += deposit;
    }

    // private functions
    function calculateProviderEarnings(uint64 providerId) private view returns (uint256 earnings) {
        // Calculate the earnings for a given provider based on subscribers count and provider fee
        // The calculation is made on per second basis.
        // Returns earnings after last balance update
        return providers[providerId].subscriberCount * (block.timestamp - providers[providerId].lastUpdated) * providers[providerId].fee / PAYMENT_FREQUENCY;
    }

    function transferBalance(address to, uint256 amount) private {
        token.transfer(to, amount);
    }

    function updateProviderBalance(uint64 providerId) private {
        Provider storage provider = providers[providerId];
        // count how much provider earned since last update: earnings = feePerSecond * secondsSinceLastUpdate * subscribersCount
        provider.balance +=  calculateProviderEarnings(providerId);
        provider.lastUpdated = uint32(block.timestamp);
    }

    // view functions
    function isProviderActive(uint64 providerId) public view providerExists(providerId) returns (bool) {
        return providersBitmap.get(providerId);
    }

    function getProviderState(uint64 providerId) external view providerExists(providerId) returns (
        uint256 subscriberCount, 
        uint256 fee, 
        address owner, 
        uint256 balance, 
        bool isActive
    ) {
        Provider memory provider = providers[providerId];
        return (provider.subscriberCount, provider.fee, provider.owner, provider.balance, isProviderActive(providerId));
    }

    function getProviderEarnings(uint64 providerId) external view providerExists(providerId) returns (uint256) {
        uint256 earnings = calculateProviderEarnings(providerId);
        return earnings;
    }

    function getSubscriberState(uint64 subscriberId) external view subscriberExists(subscriberId) returns (
        address owner, 
        uint256 balance, 
        Plan plan, 
        bool isPaused
    ) {
        Subscriber memory subscriber = subscribers[subscriberId];
        return (subscriber.owner, subscriber.balance, subscriber.plan, subscriber.pausedDate > 0);
    }

    function getSubscriberLiveBalance(uint64 subscriberId) external view subscriberExists(subscriberId) returns (uint256) {
        Subscriber memory subscriber = subscribers[subscriberId];
        uint256 fees;
        uint64[] memory providerIds = subscriberProviders[subscriberId];

        for (uint i; i < providerIds.length; i++) {
            if(isProviderActive(providerIds[i]))
                fees += providers[providerIds[i]].fee;
        }
        uint32 endDate = subscriber.pausedDate > 0 ? subscriber.pausedDate : uint32(block.timestamp);
        // calculate provider earnings as totalFeePerSecond * secondsSinceSubscription
        uint256 providerEarnings = (endDate - subscriber.createdDate) * fees / PAYMENT_FREQUENCY;

        return subscriber.balance > providerEarnings ? subscriber.balance - providerEarnings : 0;
    }
    
    // modifiers
    modifier onlyProviderOwner(uint64 providerId) {
      if(msg.sender != providers[providerId].owner)
        revert IsNotProviderOwner();
      _;
   }

   modifier providerExists(uint64 providerId) {
      if(providers[providerId].owner == address(0))
        revert ProviderDoesNotExist();
      _;
   }

    modifier subscriberExists(uint64 subscriberId) {
      if(providers[subscriberId].owner == address(0))
        revert SubscriberDoesNotExist();
      _;
   }

    modifier onlySubscriberOwner(uint64 subscriberId) {
      if(msg.sender != subscribers[subscriberId].owner)
        revert IsNotSubscriberOwner();
      _;
   }

}
