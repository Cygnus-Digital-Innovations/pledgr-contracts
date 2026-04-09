use anchor_lang::prelude::*;

#[error_code]
pub enum PledgrError {
    #[msg("Program is paused")]
    ProgramPaused,
    #[msg("Unauthorized access")]
    Unauthorized,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Subscription not active")]
    SubscriptionNotActive,
    #[msg("Payment not due")]
    PaymentNotDue,
    #[msg("Insufficient token balance")]
    InsufficientBalance,
    #[msg("Invalid token")]
    InvalidToken,
    #[msg("Arithmetic overflow")]
    ArithmeticOverflow,
    #[msg("Auto-renewal not enabled")]
    AutoRenewalNotEnabled,
    #[msg("Exceeds max allowance")]
    ExceedsMaxAllowance,
    #[msg("Creator cannot be platform wallet")]
    CreatorCannotBePlatform,
    #[msg("Token not supported")]
    TokenNotSupported,
    #[msg("Already charged this period")]
    AlreadyChargedThisPeriod,
    #[msg("Token already removed or not found")]
    TokenNotFound,
    #[msg("Invalid status transition")]
    InvalidStatusTransition,
    #[msg("Subscription price below minimum")]
    PriceTooLow,
    #[msg("Self-subscription not allowed")]
    SelfSubscriptionNotAllowed,
    #[msg("Bounty exceeds platform fee")]
    BountyExceedsPlatformFee,
    #[msg("Emergency withdraw requires paused state")]
    ProgramNotPaused,
    #[msg("Subscription is still active and within grace period")]
    SubscriptionStillActive,
}
