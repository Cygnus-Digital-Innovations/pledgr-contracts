use super::process_payment::ensure_ata_and_transfer;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{Mint, Token, TokenAccount};

#[derive(Accounts)]
#[instruction(params: SubscribeParams)]
pub struct Subscribe<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = !config.paused @ PledgrError::ProgramPaused
    )]
    pub config: Box<Account<'info, PledgrConfig>>,

    #[account(
        init,
        payer = subscriber,
        space = Subscription::LEN,
        seeds = [SUBSCRIPTION_SEED, subscriber.key().as_ref(), &params.subscription_id],
        bump
    )]
    pub subscription: Box<Account<'info, Subscription>>,

    pub payment_token_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = subscriber_token_account.owner == subscriber.key() @ PledgrError::Unauthorized,
        constraint = subscriber_token_account.mint == payment_token_mint.key() @ PledgrError::InvalidToken,
        constraint = subscriber_token_account.amount >= params.price @ PledgrError::InsufficientBalance
    )]
    pub subscriber_token_account: Box<Account<'info, TokenAccount>>,

    /// CHECK: Creator wallet
    pub creator: AccountInfo<'info>,

    /// CHECK: Creator's ATA
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
pub struct SubscribeParams {
    pub subscription_id: [u8; 32],
    pub price: u64,
    pub payment_token_mint: Pubkey,
    pub split_strategy: SplitStrategy,
    pub period_secs: u32,
    pub trial_days: Option<u64>,
    pub max_allowance: u64,
    pub fees: u64,
}

pub fn handler(ctx: Context<Subscribe>, params: SubscribeParams) -> Result<()> {
    let clock = Clock::get()?;
    let config = &ctx.accounts.config;

    let token_mint = ctx.accounts.subscriber_token_account.mint;
    require!(
        config.is_token_supported(&token_mint),
        PledgrError::InvalidToken
    );
    require!(
        token_mint == params.payment_token_mint,
        PledgrError::InvalidToken
    );
    require!(
        ctx.accounts.creator.key() != config.co_owner_one
            && ctx.accounts.creator.key() != config.co_owner_two
            && ctx.accounts.creator.key() != config.co_owner_three,
        PledgrError::CreatorCannotBePlatform
    );
    require!(
        params.price >= MIN_SUBSCRIPTION_PRICE,
        PledgrError::PriceTooLow
    );
    require!(params.period_secs > 0, PledgrError::InvalidAmount);
    require!(
        ctx.accounts.subscriber.key() != ctx.accounts.creator.key(),
        PledgrError::SelfSubscriptionNotAllowed
    );

    let created_at = clock.unix_timestamp;
    if let Some(days) = params.trial_days {
        require!(days <= 365, PledgrError::InvalidAmount);
    }
    let trial_end = params
        .trial_days
        .map(|days| created_at.saturating_add((days as i64).saturating_mul(86400)));

    let subscription = &mut ctx.accounts.subscription;
    subscription.subscription_id = params.subscription_id;
    subscription.creator = ctx.accounts.creator.key();
    subscription.subscriber = ctx.accounts.subscriber.key();
    subscription.price = params.price;
    subscription.payment_token_mint = params.payment_token_mint;
    subscription.split_strategy = params.split_strategy;
    subscription.period_secs = params.period_secs;
    subscription.grace_secs = 604800;
    subscription.created_at = created_at;
    subscription.last_charged = 0;
    subscription.status = SubscriptionStatus::Active;
    subscription.total_paid = 0;
    subscription.payment_count = 0;
    subscription.trial_end_date = trial_end;
    subscription.auto_renewal_consent = AutoRenewalConsent::default();
    subscription.bump = ctx.bumps.subscription;

    let next_due = if let Some(te) = trial_end {
        te
    } else {
        created_at
            .checked_add(params.period_secs as i64)
            .ok_or(PledgrError::ArithmeticOverflow)?
    };
    subscription.next_due = next_due;

    if trial_end.is_none() {
        let total_required = params
            .price
            .checked_add(params.fees)
            .ok_or(PledgrError::ArithmeticOverflow)?;
        require!(
            ctx.accounts.subscriber_token_account.amount >= total_required,
            PledgrError::InsufficientBalance
        );

        let (creator_amount, platform_amount) =
            params.split_strategy.calculate_amounts(params.price);

        ensure_ata_and_transfer(
            &ctx.accounts.creator.to_account_info(),
            &ctx.accounts.creator_token_account.to_account_info(),
            &ctx.accounts.payment_token_mint.to_account_info(),
            &ctx.accounts.subscriber_token_account.to_account_info(),
            &ctx.accounts.subscriber,
            &ctx.accounts.token_program,
            &ctx.accounts.associated_token_program,
            &ctx.accounts.system_program,
            creator_amount,
        )?;

        if platform_amount > 0 {
            let (wallet_amount, maintenance_amount, referral_amount) =
                config.calculate_co_owner_split(platform_amount);

            if wallet_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_one.to_account_info(),
                    &ctx.accounts.co_owner_one_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    wallet_amount,
                )?;
            }
            if maintenance_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_two.to_account_info(),
                    &ctx.accounts.co_owner_two_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    maintenance_amount,
                )?;
            }
            if referral_amount > 0 {
                ensure_ata_and_transfer(
                    &ctx.accounts.co_owner_three.to_account_info(),
                    &ctx.accounts.co_owner_three_token_account.to_account_info(),
                    &ctx.accounts.payment_token_mint.to_account_info(),
                    &ctx.accounts.subscriber_token_account.to_account_info(),
                    &ctx.accounts.subscriber,
                    &ctx.accounts.token_program,
                    &ctx.accounts.associated_token_program,
                    &ctx.accounts.system_program,
                    referral_amount,
                )?;
            }
        }

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
        }

        subscription.total_paid = params.price;
        subscription.payment_count = 1;
        subscription.last_charged = created_at;
    }

    subscription.auto_renewal_consent = AutoRenewalConsent {
        enabled: true,
        consent_timestamp: created_at,
        max_allowance: params.max_allowance,
        token_mint: params.payment_token_mint,
        product_id: u64::from_le_bytes(params.subscription_id[0..8].try_into().unwrap()),
        grace_period_end: 0,
    };

    let config = &mut ctx.accounts.config;
    config.total_processed = config
        .total_processed
        .checked_add(params.price)
        .and_then(|v| v.checked_add(if trial_end.is_none() { params.fees } else { 0 }))
        .ok_or(PledgrError::ArithmeticOverflow)?;
    config.total_subscriptions = config
        .total_subscriptions
        .checked_add(1)
        .ok_or(PledgrError::ArithmeticOverflow)?;

    emit!(SubscribeCompleted {
        subscription_id: params.subscription_id,
        subscriber: ctx.accounts.subscriber.key(),
        creator: ctx.accounts.creator.key(),
        price: params.price,
        max_allowance: params.max_allowance,
        timestamp: created_at,
    });

    Ok(())
}

#[event]
pub struct SubscribeCompleted {
    pub subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub creator: Pubkey,
    pub price: u64,
    pub max_allowance: u64,
    pub timestamp: i64,
}
