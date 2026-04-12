use anchor_lang::prelude::*;

pub mod errors;
pub mod instructions;
pub mod state;

pub use errors::*;
pub use instructions::downgrade_subscription::DowngradeSubscriptionParams;
pub use instructions::subscribe::SubscribeParams;
pub use instructions::upgrade_subscription::UpgradeSubscriptionParams;
use instructions::*;
pub use state::*;

declare_id!("J2v9sr2fvXShGJKDgX4fMmHkjeGfjy69ekqBSKLgdvEV");

#[allow(ambiguous_glob_reexports)]
#[program]
pub mod pledgr {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        platform_wallet: Pubkey,
        platform_maintenance_wallet: Pubkey,
        platform_referral_wallet: Pubkey,
        usdt_mint: Pubkey,
        usdc_mint: Pubkey,
    ) -> Result<()> {
        instructions::initialize::handler(
            ctx,
            platform_wallet,
            platform_maintenance_wallet,
            platform_referral_wallet,
            usdt_mint,
            usdc_mint,
        )
    }

    pub fn subscribe(ctx: Context<Subscribe>, params: SubscribeParams) -> Result<()> {
        instructions::subscribe::handler(ctx, params)
    }

    pub fn process_payment(
        ctx: Context<ProcessPayment>,
        amount: u64,
        payment_id: [u8; 32],
        split_strategy: Option<SplitStrategy>,
        fees: u64,
    ) -> Result<()> {
        instructions::process_payment::handler(ctx, amount, payment_id, split_strategy, fees)
    }

    pub fn process_auto_renewal(
        ctx: Context<ProcessAutoRenewal>,
        subscription_id: [u8; 32],
    ) -> Result<()> {
        instructions::process_auto_renewal::handler(ctx, subscription_id)
    }

    pub fn cancel_subscription(ctx: Context<CancelSubscription>) -> Result<()> {
        instructions::cancel_subscription::handler(ctx)
    }

    pub fn close_subscription(ctx: Context<CloseSubscription>) -> Result<()> {
        instructions::close_subscription::handler(ctx)
    }

    pub fn set_auto_renewal_consent(
        ctx: Context<SetAutoRenewalConsent>,
        enabled: bool,
        max_allowance: u64,
    ) -> Result<()> {
        instructions::set_auto_renewal_consent::handler(ctx, enabled, max_allowance)
    }

    pub fn update_status(ctx: Context<UpdateStatus>, new_status: SubscriptionStatus) -> Result<()> {
        instructions::update_status::handler(ctx, new_status)
    }

    pub fn toggle_pause(ctx: Context<TogglePause>, paused: bool) -> Result<()> {
        instructions::toggle_pause::handler(ctx, paused)
    }

    pub fn add_supported_token(ctx: Context<AddSupportedToken>) -> Result<()> {
        instructions::add_supported_token::handler(ctx)
    }

    pub fn remove_supported_token(
        ctx: Context<RemoveSupportedToken>,
        token_mint: Pubkey,
    ) -> Result<()> {
        instructions::remove_supported_token::handler(ctx, token_mint)
    }

    pub fn set_co_owner(
        ctx: Context<SetCoOwner>,
        new_co_owner_one: Pubkey,
        new_co_owner_two: Pubkey,
        new_co_owner_three: Pubkey,
    ) -> Result<()> {
        instructions::set_platform_wallet::handler(
            ctx,
            new_co_owner_one,
            new_co_owner_two,
            new_co_owner_three,
        )
    }

    pub fn update_co_owner_one(ctx: Context<UpdateCoOwnerOne>, new_wallet: Pubkey) -> Result<()> {
        instructions::update_platform_wallet::handler(ctx, new_wallet)
    }

    pub fn update_co_owner_two(ctx: Context<UpdateCoOwnerTwo>, new_wallet: Pubkey) -> Result<()> {
        instructions::update_platform_wallet::update_co_owner_two_handler(ctx, new_wallet)
    }

    pub fn update_co_owner_three(
        ctx: Context<UpdateCoOwnerThree>,
        new_wallet: Pubkey,
    ) -> Result<()> {
        instructions::update_platform_wallet::update_co_owner_three_handler(ctx, new_wallet)
    }

    pub fn emergency_withdraw(ctx: Context<EmergencyWithdraw>) -> Result<()> {
        instructions::emergency_withdraw::handler(ctx)
    }

    pub fn set_bounty_config(
        ctx: Context<SetBountyConfig>,
        bounty_per_renewal: u64,
        max_bounty_per_tx: u64,
        enabled: bool,
    ) -> Result<()> {
        instructions::manage_executors::set_bounty_config_handler(
            ctx,
            bounty_per_renewal,
            max_bounty_per_tx,
            enabled,
        )
    }

    pub fn upgrade_subscription(
        ctx: Context<UpgradeSubscription>,
        params: UpgradeSubscriptionParams,
    ) -> Result<()> {
        instructions::upgrade_subscription::handler(ctx, params)
    }

    pub fn downgrade_subscription(
        ctx: Context<DowngradeSubscription>,
        params: DowngradeSubscriptionParams,
    ) -> Result<()> {
        instructions::downgrade_subscription::handler(ctx, params)
    }

    pub fn batch_renewal(ctx: Context<BatchRenewal>) -> Result<()> {
        instructions::batch_renewal::handler(ctx)
    }
}
