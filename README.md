# Provider-Subscriber system


This repository contains two solutions for the assignment. 

### ProviderControllerV1

This solution allows Provider to charge its subscribers on monthly basis. `Provider` struct has `nextWithdrawal` timestamp that is updated on each withdrawal. The contract doesn't allow to withdraw before `nextWithdrawal`

### ProviderControllerV2

In this solution subscribers are charged on per-second basis. Provider's balance is updated on each addition/removal of a subscriber. It allows more precise calculation of fees and also adds posiibility to update Provider's fees at any time.

### Known issues

+ Calculation in `getSubscriberLiveBalance` is not accurate when Provider has charged some amount and then has been removed
+ `calculateProviderEarnings` of ProviderControllerV1 may be exploited by not withdrawing funds every month by Provider. If the number of subscribers grow, Provider will receive more earnings than it should by withdrawing funds later.
There is no such issue in ProviderControllerV2
+ There is no way to unpause subscriber
+ There should be a way to block subscribers that have not enough balance

## Bonus Section
### Balance Management

ProviderControllerV2 has implementation that allows per-second subscription. It can be changed to charge by hour etc.

### System Scalability

The function `updateProvidersState` can be updated in a way to set bitmap in memory and then writing it to storage.
Other then that current solution is scalable enough to have many providers as long as we have the limitation on the number of providers for each individual subscriber (14 currently).

### Changing Provider Fees

ProviderControllerV2 allows changing provider fees and calculates provider's balance correctly. But additional logic needs to be implemented for calculating subscriber's live balance

