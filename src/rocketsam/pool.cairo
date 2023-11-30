#[starknet::contract]
mod Pool {
    use array::{ ArrayTrait, SpanTrait };
    use integer::BoundedInt;
    use option::OptionTrait;
    use starknet::{
        ContractAddress,
        get_caller_address, 
        get_contract_address, 
        contract_address_try_from_felt252
    };
    use traits::TryInto;
    use zeroable::Zeroable;

    use openzeppelin::access::ownable::Ownable;
    use openzeppelin::access::ownable::interface::{
        IOwnable, 
        IOwnableCamelOnly,
    };
    use openzeppelin::security::reentrancyguard::ReentrancyGuard;
    use openzeppelin::security::pausable::{
        Pausable, 
        IPausable,
    };
    use openzeppelin::token::erc20::interface::{ 
        IERC20CamelDispatcherTrait, 
        IERC20CamelDispatcher,
    };

    ///////////////////////
    ///    CONSTANTS    ///
    ///////////////////////

    const ETH_ADDRESS: felt252 = 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;

    const DENOMINATOR: u16 = 10000;

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct AddressStatistics {
        deposits_count: u256,
        deposits_volume: u256,
    }


    ///////////////////////
    ///     STORAGE     ///
    ///////////////////////
    #[storage]
    struct Storage {
        _pool_id: u256,

        _fees: LegacyMap<u256, u256>,
        _values: LegacyMap<u32, u256>,
        _values_length: u32,
        _max_fee: u256,
        _fee_collector: ContractAddress,

        _fee_earned: u256,
        _fee_claimed: u256,
        _balances: LegacyMap<ContractAddress, u256>,
        _deposits_count: u256,
        _deposits_volume: u256,
        _address_statistics: LegacyMap<ContractAddress, AddressStatistics>,

        _referral_bips_common: u16,
        _referrer_bips: LegacyMap<ContractAddress, u16>,
        _referrer_earned: LegacyMap<ContractAddress, u256>,
        _referrer_claimed: LegacyMap<ContractAddress, u256>,
        _referrer_tx_count: LegacyMap<ContractAddress, u256>,
    }

    ///////////////////////
    ///     ERRORS      ///
    ///////////////////////
    mod Errors {
        const INCORRECT_FEE_VALUES: felt252 = 'Fees and values len not equal';
        const INVALID_FEE_COLLECTOR: felt252 = 'Invalid fee collector address';
        const INVALID_BALANCE: felt252 = 'Deposit balance is zero';
        const FAILED_TO_SEND_ETH: felt252 = 'ETH sending failed';
        const NOTHING_TO_CLAIM: felt252 = 'Nothing to claim';
        const INVALID_REFERRAL_BIPS: felt252 = 'Referral bips too high';
        const INVALID_REFERRER: felt252 = 'Invalid referrer address';
        const INCORRECT_ALLOWANCE: felt252 = 'Fee exceeds allowance';
        const CALLER_NOT_FEE_COLLECTOR: felt252 = 'Caller is not fee collector';
    }

    ///////////////////////
    ///     EVENTS      ///
    ///////////////////////
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        FeeChanged: FeeChanged,
        MaxFeeChanged: MaxFeeChanged,
        FeeCollectorChanged: FeeCollectorChanged,
        CommonRefBipsChanged: CommonRefBipsChanged,
        ReferrerBipsChanged: ReferrerBipsChanged,
        Deposit: Deposit,
        Withdraw: Withdraw,
        FeeClaimed: FeeClaimed,
        ReferralClaimed: ReferralClaimed,
    }

    #[derive(Drop, starknet::Event)]
    struct FeeChanged { values: Span<u256>, fees: Span<u256>, max_fee: u256 }
    #[derive(Drop, starknet::Event)]
    struct MaxFeeChanged { #[key] old_max_fee: u256, #[key] new_max_fee: u256 }
    #[derive(Drop, starknet::Event)]
    struct FeeCollectorChanged { #[key] old_fee_collector: ContractAddress, #[key] new_fee_collector: ContractAddress }
    #[derive(Drop, starknet::Event)]
    struct CommonRefBipsChanged { #[key] old_bips: u16, #[key] new_bips: u16 }
    #[derive(Drop, starknet::Event)]
    struct ReferrerBipsChanged { #[key] referrer: ContractAddress, old_bips: u16, new_bips: u16 }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        depositer: ContractAddress,
        fee_earned: u256,
        amount: u256,
        balance: u256,
        #[key]
        referrer: ContractAddress,
        referrer_share: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct Withdraw { #[key] depositer: ContractAddress, amount: u256 }
    #[derive(Drop, starknet::Event)]
    struct FeeClaimed { #[key] collector: ContractAddress, amount: u256 }
    #[derive(Drop, starknet::Event)]
    struct ReferralClaimed { #[key] referrer: ContractAddress, amount: u256 }

    /////////////////////
    ///  CONSTRUCTOR  ///
    /////////////////////
    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        pool_id: u256,
        fee: u256,
        fee_collector: ContractAddress,
        referral_earning_bips: u16,
    ) {
        let mut ownable_unsafe_state = Ownable::unsafe_new_contract_state();
        Ownable::InternalImpl::initializer(ref ownable_unsafe_state, owner);
        
        self._pool_id.write(pool_id);
        self._max_fee.write(fee);
        self._referral_bips_common.write(referral_earning_bips);
        self._fee_collector.write(fee_collector);
    }

    ////////////////////////////
    ///  EXTERNAL FUNCTIONS  ///
    ////////////////////////////
    #[external(v0)]
    #[generate_trait]
    impl PoolImpl of PoolTrait {

        fn setFee(ref self: ContractState, values: Span<u256>, fees: Span<u256>, max_fee: u256) {
            Modifier::only_owner(@self);
            assert(fees.len() == values.len(), Errors::INCORRECT_FEE_VALUES);
            
            let current_values_length = self._values_length.read();
            let mut i: u32 = 0;
            loop {
                if i == current_values_length {
                    break;
                }
                self._values.write(i, 0);
                i += 1;
            };

            self._values_length.write(values.len());
            self._max_fee.write(max_fee);
            let mut j: u32 = 0;
            loop {
                if j == values.len() {
                    break;
                }
                let value = *values.at(j);
                self._values.write(j, value);
                self._fees.write(value, *fees.at(j));
                j += 1;
            };

            self.emit(FeeChanged { 
                values: values, 
                fees: fees, max_fee: 
                max_fee 
            });
        }

        fn setMaxFee(ref self: ContractState, max_fee: u256) {
            Modifier::only_owner(@self);

            let old_max_fee = self._max_fee.read();
            self._max_fee.write(max_fee);

            self.emit(MaxFeeChanged { old_max_fee: old_max_fee, new_max_fee: max_fee });
        }

        fn setFeeCollector(ref self: ContractState, fee_collector: ContractAddress) {
            Modifier::only_owner(@self);
            assert(fee_collector.is_non_zero(), Errors::INVALID_FEE_COLLECTOR);

            let old_fee_collector = self._fee_collector.read();
            self._fee_collector.write(fee_collector);

            self.emit(FeeCollectorChanged { old_fee_collector: old_fee_collector, new_fee_collector: fee_collector });
        }

        fn setReferralEarningBips(ref self: ContractState, earning_bips: u16) {
            Modifier::only_owner(@self);
            assert(earning_bips <= DENOMINATOR, Errors::INVALID_REFERRAL_BIPS);

            let old_earning_bips = self._referral_bips_common.read();
            self._referral_bips_common.write(earning_bips);

            self.emit(CommonRefBipsChanged {
                old_bips: old_earning_bips,
                new_bips: earning_bips,
            });
        }

        fn setEarningBipsForReferrer(
            ref self: ContractState, 
            referrer: ContractAddress, 
            earning_bips: u16,
        ) {
            Modifier::only_owner(@self);
            assert(earning_bips <= DENOMINATOR, Errors::INVALID_REFERRAL_BIPS);

            let old_earning_bips = self._referrer_bips.read(referrer);
            self._referrer_bips.write(referrer, earning_bips);

            self.emit(ReferrerBipsChanged {
                referrer: referrer,
                old_bips: old_earning_bips,
                new_bips: earning_bips,
            })
        }

        fn getPoolId(self: @ContractState) -> u256 {
            self._pool_id.read()
        }

        fn getFee(self: @ContractState, value: u256) -> u256 {
            self._fees.read(value)
        }

        fn getValues(self: @ContractState) -> Span<u256> {
            let mut values = ArrayTrait::<u256>::new();
            let values_length = self._values_length.read();
            let mut i: u32 = 0;
            loop {
                if i == values_length {
                    break;
                }
                values.append(self._values.read(i));
                i += 1;
            };
            return values.span();
        }

        fn getMaxFee(self: @ContractState) -> u256 {
            self._max_fee.read()
        }

        fn getFeeCollector(self: @ContractState) -> ContractAddress {
            self._fee_collector.read()
        }

        fn getBalance(self: @ContractState, address: ContractAddress) -> u256 {
            self._balances.read(address)
        }

        fn getAddressStatistics(self: @ContractState, address: ContractAddress) -> AddressStatistics {
            self._address_statistics.read(address)
        }

        fn getDepositsCount(self: @ContractState) -> u256 {
            self._deposits_count.read()
        }

        fn getDepositsVolume(self: @ContractState) -> u256 {
            self._deposits_volume.read()
        }

        fn getFeeEarnedAmount(self: @ContractState) -> u256 {
            self._fee_earned.read()
        }

        fn getFeeClaimedAmount(self: @ContractState) -> u256 {
            self._fee_claimed.read()
        }

        fn estimateProtocolFee(self: @ContractState, amount: u256) -> u256 {
            let max_int: u256 = BoundedInt::max();
            let mut min_value = max_int;
            let values_length = self._values_length.read();
            let mut i: u32 = 0;
            loop {
                if i == values_length {
                    break;
                }
                let value = self._values.read(i);
                if amount <= value && value < min_value {
                    min_value = value;
                }
                i += 1;
            };
            if min_value == max_int && self._fees.read(max_int) == 0 {
                return self._max_fee.read();
            }
            return self._fees.read(min_value);
        }

        fn deposit(ref self: ContractState, amount: u256) {
            Modifier::when_not_paused(@self);

            let mut unsafe_rg_state = ReentrancyGuard::unsafe_new_contract_state();
            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);

            self._deposit(amount, Zeroable::zero());

            ReentrancyGuard::InternalImpl::end(ref unsafe_rg_state);
        }

        fn depositWithReferrer(ref self: ContractState, referrer: ContractAddress, amount: u256) {
            Modifier::when_not_paused(@self);

            let mut unsafe_rg_state = ReentrancyGuard::unsafe_new_contract_state();
            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);

            self._deposit(amount, referrer);

            ReentrancyGuard::InternalImpl::end(ref unsafe_rg_state);
        }

        fn withdraw(ref self: ContractState) {
            let mut unsafe_rg_state = ReentrancyGuard::unsafe_new_contract_state();
            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);

            let caller = get_caller_address();
            let balance = self._balances.read(caller);
            assert(balance > 0, Errors::INVALID_BALANCE);

            self._balances.write(caller, 0);

            let success = self._eth_dispatcher().transfer(caller, balance);
            assert(success, Errors::FAILED_TO_SEND_ETH);

            self.emit(Withdraw {
                depositer: caller,
                amount: balance,
            });
            
            ReentrancyGuard::InternalImpl::end(ref unsafe_rg_state);
        }

        fn claimFeeEarnings(ref self: ContractState) {
            Modifier::only_fee_collector(@self);

            let mut unsafe_rg_state = ReentrancyGuard::unsafe_new_contract_state();
            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);

            let earned = self._fee_earned.read();
            assert(earned > 0, Errors::NOTHING_TO_CLAIM);

            self._fee_earned.write(0);
            self._fee_claimed.write(self._fee_claimed.read() + earned);

            let fee_collector = self._fee_collector.read();
            let success = self._eth_dispatcher().transfer(fee_collector, earned);
            assert(success, Errors::FAILED_TO_SEND_ETH);

            self.emit(FeeClaimed {
                collector: fee_collector,
                amount: earned,
            });
            
            ReentrancyGuard::InternalImpl::end(ref unsafe_rg_state);
        }

        fn claimReferralEarnings(ref self: ContractState) {
            let mut unsafe_rg_state = ReentrancyGuard::unsafe_new_contract_state();
            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);
            let caller = get_caller_address();
            let earned = self._referrer_earned.read(caller);
            assert(earned > 0, Errors::NOTHING_TO_CLAIM);

            self._referrer_earned.write(caller, 0);
            self._referrer_claimed.write(caller, self._referrer_claimed.read(caller) + earned);

            let success = self._eth_dispatcher().transfer(caller, earned);
            assert(success, Errors::FAILED_TO_SEND_ETH);

            self.emit(ReferralClaimed {
                referrer: caller,
                amount: earned,
            });

            ReentrancyGuard::InternalImpl::start(ref unsafe_rg_state);
        }
    }

    ////////////////////////////
    ///  INTERNAL FUNCTIONS  ///
    ////////////////////////////
    #[generate_trait]
    impl InternalImpl of InternalTrait {

        fn _eth_dispatcher(self: @ContractState) -> IERC20CamelDispatcher {
            let eth_contract = contract_address_try_from_felt252(ETH_ADDRESS).unwrap();
            IERC20CamelDispatcher { contract_address: eth_contract }
        }

        fn _estimate_referrer_earnings(self: @ContractState, referrer: ContractAddress, fee: u256) -> u256 {
            let referrer_custom_bips = self._referrer_bips.read(referrer);
            let referrer_bips = if referrer_custom_bips == 0 {
                self._referral_bips_common.read()
            } else {
                referrer_custom_bips
            }.into();

            return (fee * referrer_bips) / DENOMINATOR.into();
        }

        fn _deposit(ref self: ContractState, amount: u256, referrer: ContractAddress) {
            let caller = get_caller_address();
            assert(caller != referrer, Errors::INVALID_REFERRER);

            let fee = self.estimateProtocolFee(amount);
            let amount_to_transfer = amount + fee;
            let this_contract = get_contract_address();
            let eth_dispatcher = self._eth_dispatcher();
            let allowance = eth_dispatcher.allowance(caller, this_contract);
            assert(allowance >= amount_to_transfer, Errors::INCORRECT_ALLOWANCE);

            let mut referral_earnings: u256 = 0;
            if referrer.is_non_zero() {
                referral_earnings = self._estimate_referrer_earnings(referrer, fee);
                
                self._referrer_tx_count.write(
                    referrer,
                    self._referrer_tx_count.read(referrer) + 1
                );
                self._referrer_earned.write(
                    referrer, 
                    self._referrer_earned.read(referrer) + referral_earnings
                );
            }
            let protocol_earnings: u256 = fee - referral_earnings;

            self._fee_earned.write(self._fee_earned.read() + protocol_earnings);
            self._balances.write(caller, self._balances.read(caller) + amount);
            self._deposits_count.write(self._deposits_count.read() + 1);
            self._deposits_volume.write(self._deposits_volume.read() + amount);
            let statistics: AddressStatistics = self._address_statistics.read(caller);
            self._address_statistics.write(caller, AddressStatistics { 
                deposits_count: statistics.deposits_count + 1, 
                deposits_volume: statistics.deposits_volume + amount, 
            });

            let success = eth_dispatcher.transferFrom(caller, this_contract, amount_to_transfer);
            assert(success, Errors::FAILED_TO_SEND_ETH);

            self.emit(Deposit {
                depositer: caller,
                fee_earned: protocol_earnings,
                amount: amount,
                balance: self._balances.read(caller),
                referrer: referrer,
                referrer_share: referral_earnings,
            });
        }
    }

    //
    // Modifier helpers
    //
    #[generate_trait]
    impl Modifier of ModifierTrait {

        #[inline(always)]
        fn only_owner(self: @ContractState) {
            let unsafe_state = Ownable::unsafe_new_contract_state();
            Ownable::InternalImpl::assert_only_owner(@unsafe_state);
        }

        #[inline(always)]
        fn only_fee_collector(self: @ContractState) {
            let caller = get_caller_address();
            assert(self._fee_collector.read() == caller, Errors::CALLER_NOT_FEE_COLLECTOR);
        }

        #[inline(always)]
        fn when_not_paused(self: @ContractState) {
            let unsafe_state = Pausable::unsafe_new_contract_state();
            Pausable::InternalImpl::assert_not_paused(@unsafe_state);
        }
    }

    ///////////////////
    ///  OVERRIDES  ///
    ///////////////////
    //
    // Pausable Implementation
    //
    #[external(v0)]
    impl PausableImpl of IPausable<ContractState> {
        fn is_paused(self: @ContractState) -> bool {
            let unsafe_state = Pausable::unsafe_new_contract_state();
            Pausable::PausableImpl::is_paused(@unsafe_state)
        }
    }

    #[external(v0)]
    #[generate_trait]
    impl GovPausableImpl of PausableTrait {

        fn pause(ref self: ContractState) {
            Modifier::only_owner(@self);
            let mut unsafe_state = Pausable::unsafe_new_contract_state();
            Pausable::InternalImpl::assert_not_paused(@unsafe_state);
            Pausable::InternalImpl::_pause(ref unsafe_state)
        }

        fn unpause(ref self: ContractState) {
            Modifier::only_owner(@self);
            let mut unsafe_state = Pausable::unsafe_new_contract_state();
            Pausable::InternalImpl::assert_paused(@unsafe_state);
            Pausable::InternalImpl::_unpause(ref unsafe_state)
        }
    }

    //
    // Ownable Implementation
    //
    #[external(v0)]
    impl OwnableImpl of IOwnable<ContractState> {

        fn owner(self: @ContractState) -> ContractAddress {
            let unsafe_state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::owner(@unsafe_state)
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let mut unsafe_state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::transfer_ownership(ref unsafe_state, new_owner);
        }

        fn renounce_ownership(ref self: ContractState) {
            let mut unsafe_state = Ownable::unsafe_new_contract_state();
            Ownable::OwnableImpl::renounce_ownership(ref unsafe_state);
        }
    }

    //
    // Ownable camel only Implementation
    //
    #[external(v0)]
    impl OwnableCamelOnlyImpl of IOwnableCamelOnly<ContractState> {

        fn transferOwnership(ref self: ContractState, newOwner: ContractAddress) {
            self.transfer_ownership(newOwner);
        }

        fn renounceOwnership(ref self: ContractState) {
            self.renounce_ownership();
        }
    }
}
