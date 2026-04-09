use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct SetAutoRenewalConsent<'info> {
    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, subscription.subscriber.as_ref(), &subscription.subscription_id],
        bump = subscription.bump,
        constraint = subscriber.key() == subscription.subscriber @ PledgrError::Unauthorized
    )]
    pub subscription: Account<'info, Subscription>,

    pub subscriber: Signer<'info>,
}

pub fn handler(
    ctx: Context<SetAutoRenewalConsent>,
    enabled: bool,
    max_allowance: u64,
) -> Result<()> {
    let subscription = &mut ctx.accounts.subscription;
    let clock = Clock::get()?;

    require!(
        subscription.status != SubscriptionStatus::Cancelled,
        PledgrError::SubscriptionNotActive
    );

    if enabled {
        require!(max_allowance > 0, PledgrError::InvalidAmount);
    }

    subscription.auto_renewal_consent = AutoRenewalConsent {
        enabled,
        consent_timestamp: clock.unix_timestamp,
        max_allowance: if enabled { max_allowance } else { 0 },
        token_mint: subscription.payment_token_mint,
        product_id: u64::from_le_bytes(subscription.subscription_id[0..8].try_into().unwrap()),
        grace_period_end: 0,
    };

    emit!(AutoRenewalConsentSet {
        subscription_id: subscription.subscription_id,
        subscriber: subscription.subscriber,
        enabled,
        max_allowance,
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct AutoRenewalConsentSet {
    pub subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub enabled: bool,
    pub max_allowance: u64,
    pub timestamp: i64,
}
