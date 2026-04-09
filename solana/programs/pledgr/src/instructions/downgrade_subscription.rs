use super::process_payment::ensure_ata_and_transfer;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{Mint, Token, TokenAccount};

#[derive(Accounts)]
#[instruction(params: DowngradeSubscriptionParams)]
pub struct DowngradeSubscription<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = !config.paused @ PledgrError::ProgramPaused
    )]
    pub config: Box<Account<'info, PledgrConfig>>,

    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, old_subscription.subscriber.as_ref(), &old_subscription.subscription_id],
        bump = old_subscription.bump,
        constraint = old_subscription.status == SubscriptionStatus::Active @ PledgrError::SubscriptionNotActive,
        constraint = old_subscription.subscriber == subscriber.key() @ PledgrError::Unauthorized
    )]
    pub old_subscription: Account<'info, Subscription>,

    #[account(
        init,
        payer = subscriber,
        space = Subscription::LEN,
        seeds = [SUBSCRIPTION_SEED, subscriber.key().as_ref(), &params.new_subscription_id],
        bump
    )]
    pub new_subscription: Box<Account<'info, Subscription>>,

    pub payment_token_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = subscriber_token_account.owner == subscriber.key() @ PledgrError::Unauthorized,
        constraint = subscriber_token_account.mint == payment_token_mint.key() @ PledgrError::InvalidToken
    )]
    pub subscriber_token_account: Box<Account<'info, TokenAccount>>,

    /// CHECK: Validated against old_subscription.creator in handler
    pub creator: AccountInfo<'info>,

    /// CHECK: Creator's ATA, validated via ensure_ata_and_transfer
    #[account(mut)]
    pub creator_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_one.key() == config.co_owner_one @ PledgrError::Unauthorized)]
    pub co_owner_one: UncheckedAccount<'info>,

    /// CHECK: Platform ATA
    #[account(mut)]
    pub co_owner_one_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_two.key() == config.co_owner_two @ PledgrError::Unauthorized)]
    pub co_owner_two: UncheckedAccount<'info>,

    /// CHECK: Maintenance ATA
    #[account(mut)]
    pub co_owner_two_token_account: UncheckedAccount<'info>,

    /// CHECK: Validated against config
    #[account(constraint = co_owner_three.key() == config.co_owner_three @ PledgrError::Unauthorized)]
    pub co_owner_three: UncheckedAccount<'info>,

    /// CHECK: Referral ATA
    #[account(mut)]
    pub co_owner_three_token_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub subscriber: Signer<'info>,

    pub associated_token_program: Program<'info, AssociatedToken>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct DowngradeSubscriptionParams {
    pub old_subscription_id: [u8; 32],
    pub new_subscription_id: [u8; 32],
    pub new_price: u64,
    pub new_period_secs: u32,
    pub fees: u64,
}

pub fn handler(
    ctx: Context<DowngradeSubscription>,
    params: DowngradeSubscriptionParams,
) -> Result<()> {
    let clock = Clock::get()?;
    let config = &mut ctx.accounts.config;
    let old_subscription = &mut ctx.accounts.old_subscription;

    require!(
        params.old_subscription_id == old_subscription.subscription_id,
        PledgrError::Unauthorized
    );

    let token_mint = ctx.accounts.subscriber_token_account.mint;
    require!(
        config.is_token_supported(&token_mint),
        PledgrError::InvalidToken
    );
    require!(
        token_mint == old_subscription.payment_token_mint,
        PledgrError::InvalidToken
    );
    require!(
        ctx.accounts.creator.key() == old_subscription.creator,
        PledgrError::Unauthorized
    );
    require!(
        ctx.accounts.creator.key() != config.co_owner_one
            && ctx.accounts.creator.key() != config.co_owner_two
            && ctx.accounts.creator.key() != config.co_owner_three,
        PledgrError::CreatorCannotBePlatform
    );
    require!(
        params.new_price >= MIN_SUBSCRIPTION_PRICE,
        PledgrError::PriceTooLow
    );
    require!(params.new_period_secs > 0, PledgrError::InvalidAmount);
    require!(
        ctx.accounts.subscriber.key() != ctx.accounts.creator.key(),
        PledgrError::SelfSubscriptionNotAllowed
    );

    let old_price = old_subscription.price;
    require!(params.new_price < old_price, PledgrError::InvalidAmount);

    if params.fees > 0 {
        require!(
            ctx.accounts.subscriber_token_account.amount >= params.fees,
            PledgrError::InsufficientBalance
        );
    }

    let old_auto_renewal_enabled = old_subscription.auto_renewal_consent.enabled;
    let old_max_allowance = old_subscription.auto_renewal_consent.max_allowance;

    old_subscription.status = SubscriptionStatus::Cancelled;
    old_subscription.auto_renewal_consent.enabled = false;
    old_subscription.auto_renewal_consent.max_allowance = 0;

    let created_at = clock.unix_timestamp;
    let next_due = old_subscription.next_due;

    let new_subscription = &mut ctx.accounts.new_subscription;
    new_subscription.subscription_id = params.new_subscription_id;
    new_subscription.creator = ctx.accounts.creator.key();
    new_subscription.subscriber = ctx.accounts.subscriber.key();
    new_subscription.price = params.new_price;
    new_subscription.payment_token_mint = old_subscription.payment_token_mint;
    new_subscription.split_strategy = old_subscription.split_strategy;
    new_subscription.period_secs = params.new_period_secs;
    new_subscription.next_due = next_due;
    new_subscription.grace_secs = old_subscription.grace_secs;
    new_subscription.created_at = created_at;
    new_subscription.last_charged = old_subscription.last_charged;
    new_subscription.status = SubscriptionStatus::Active;
    new_subscription.total_paid = old_subscription.total_paid;
    new_subscription.payment_count = old_subscription.payment_count;
    new_subscription.trial_end_date = old_subscription.trial_end_date;
    new_subscription.bump = ctx.bumps.new_subscription;

    new_subscription.auto_renewal_consent = AutoRenewalConsent {
        enabled: old_auto_renewal_enabled,
        consent_timestamp: old_subscription.auto_renewal_consent.consent_timestamp,
        max_allowance: old_max_allowance,
        token_mint: old_subscription.payment_token_mint,
        product_id: u64::from_le_bytes(params.new_subscription_id[0..8].try_into().unwrap()),
        grace_period_end: old_subscription.auto_renewal_consent.grace_period_end,
    };

    if params.fees > 0 {
        ensure_ata_and_transfer(
            &ctx.accounts.co_owner_three.to_account_info(),
            &ctx.accounts.co_owner_three_token_account.to_account_info(),
            &ctx.accounts.payment_token_mint.to_account_info(),
            &ctx.accounts.subscriber_token_account.to_account_info(),
            &ctx.accounts.subscriber,
            &ctx.accounts.token_program,
            &ctx.accounts.associated_token_program,
            &ctx.accounts.system_program,
            params.fees,
        )?;

        config.total_processed = config
            .total_processed
            .checked_add(params.fees)
            .ok_or(PledgrError::ArithmeticOverflow)?;
    }

    config.total_subscriptions = config
        .total_subscriptions
        .checked_add(1)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    emit!(SubscriptionDowngraded {
        old_subscription_id: params.old_subscription_id,
        new_subscription_id: params.new_subscription_id,
        subscriber: ctx.accounts.subscriber.key(),
        old_price,
        new_price: params.new_price,
        timestamp: created_at,
    });

    Ok(())
}

#[event]
pub struct SubscriptionDowngraded {
    pub old_subscription_id: [u8; 32],
    pub new_subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub old_price: u64,
    pub new_price: u64,
    pub timestamp: i64,
}
