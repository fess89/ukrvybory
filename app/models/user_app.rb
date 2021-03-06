class UserApp < ActiveRecord::Base
  include FullNameFormable

  serialize :social_accounts, HashWithIndifferentAccess
  belongs_to :region
  belongs_to :adm_region, class_name: "Region"
  belongs_to :organisation
  has_many :user_app_current_roles, dependent: :destroy, :autosave => true
  has_many :current_roles, through: :user_app_current_roles
  has_one :user
  accepts_nested_attributes_for :user_app_current_roles

  #наблюдатель, участник мобильной группы, территориальный координатор, координатор мобильной группы, оператор горячей линии
  NO_STATUS, STATUS_OBSERVER, STATUS_MOBILE, STATUS_COORD_REGION, STATUS_COORD_MOBILE, STATUS_CALLER, STATUS_COORD_CALLER = 0, 1, 2, 4, 8, 16, 16384

  #Член ПРГ в резерве, Член ПРГ УИК, Член ПСГ ТИК, Член ПРГ ТИК
  STATUS_PRG_RESERVE, STATUS_PRG, STATUS_TIC_PSG, STATUS_TIC_PRG = 32, 64, 128, 256

  #Член ПСГ УИК, кандидат, доверенное лицо кандидата, журналист освещающий выборы, координатор
  STATUS_PSG, STATUS_CANDIDATE, STATUS_DELEGATE, STATUS_JOURNALIST, STATUS_COORD, STATUS_LAWYER = 512, 1024, 2048, 4096, 8192, 32768

  LEGAL_STATUS_NO, LEGAL_STATUS_YES, LEGAL_STATUS_LAWYER = 0, 1, 3

  validates :data_processing_allowed, acceptance: { :message => "Требуется подтвердить" }

  validates :first_name, :presence => true
  validates :last_name,  :presence => true
  validates :patronymic,  :presence => true
  validates :email, :email => true, :allow_blank => true
  validates :email, :presence => true, :unless => :imported?
  validates :phone, :presence => true, uniqueness: { scope: :state }, format: { with: /\A\d{10}\z/ } #TODO это более мягкая проверка, чем в валидаторе на форме (уникальность внутри одного статуса, а там - среди всех статусов кроме rejected)
  validates :adm_region, :presence => true
  validates :desired_statuses, :presence => true, :exclusion => { :in => [NO_STATUS], :message => "Требуется выбрать хотя бы один вариант" }
  validates :has_car, :inclusion =>  { :in => [true, false], :message => "требуется указать" }
  validates :has_video, :inclusion =>  { :in => [true, false], :message => "требуется указать" }
  validates :legal_status, :inclusion =>  { :in => [LEGAL_STATUS_NO, LEGAL_STATUS_YES, LEGAL_STATUS_LAWYER] }
  validates :experience_count, :presence => true
  validates :experience_count,
            :numericality  => {:only_integer => true, :equal_to => 0, :message => "Если у Вас был опыт, поставьте соответствующие отметки"},
            if: Proc.new { |a| a.previous_statuses == NO_STATUS }
  validates :experience_count,
            :numericality  => {:only_integer => true, :greater_than => 0, :message => "Если у Вас был опыт, то количество раз - как минимум 1"},
            unless: Proc.new { |a| a.previous_statuses == NO_STATUS }

  validates :sex_male, :inclusion =>  { :in => [true, false], :message => "требуется указать" }
  validates :year_born,
            :presence => true,
            :numericality  => {:only_integer => true, :greater_than => 1900, :less_than => 2000,  :message => "Неверный формат"}

  validates :ip, :presence => true
  validates :uic, format: {with: /\A([0-9]+)(,\s*[0-9]+)*\z/}, allow_blank: true

  validate :check_regions
  validate :check_phone_verified, on: :create
  validate :check_uic_belongs_to_region

  attr_accessor :verification, :skip_phone_verification, :skip_email_confirmation

  before_validation :set_phone_verified_status, on: :create

  after_create :send_email_confirmation, :unless => :skip_email_confirmation

  state_machine initial: :pending do
    state :approved
    state :imported
    state :pending
    state :rejected
    state :spammed

    event :spam do
      transition all => :spammed
    end

    event :reject do
      transition all => :rejected
    end
    
    event :set_imported do
      transition :pending => :imported
    end

    event :approve do
      transition [:pending, :rejected, :imported] => :approved
    end
  end

  SOCIAL_ACCOUNTS = {vk: "ВКонтакте", fb: "Facebook", twitter: "Twitter", lj: "LiveJournal"}
  SOCIAL_ACCOUNTS.each do |provider_key, provider_name|
    method_n = 'social_'+provider_key.to_s
    define_method(method_n) { social_accounts[provider_key] }
    define_method(method_n+'=') do |val|
      self.social_accounts[provider_key] = val
    end
  end

  def self.all_future_statuses
    {
      STATUS_OBSERVER => "observer",
      STATUS_MOBILE => "mobile",
      STATUS_CALLER => "caller",
      STATUS_COORD_REGION => "coord_region",
      STATUS_COORD_MOBILE => "coord_mobile",
      STATUS_COORD_CALLER => "coord_caller"
    }
  end

  def self.all_future_statuses_with_archived
    all_future_statuses.merge STATUS_PRG_RESERVE => "prg_reserve"
  end

  def self.future_statuses_methods
    self.all_future_statuses.values.collect{ |v| "can_be_#{v}" }
  end

  def self.all_previous_statuses
    {
      STATUS_OBSERVER => "observer",
      STATUS_MOBILE => "mobile",
      STATUS_PRG => "prg",
      STATUS_PSG => "psg",
      STATUS_TIC_PRG => "tic_prg",
      STATUS_TIC_PSG => "tic_psg",
      STATUS_LAWYER => "lawyer",
      STATUS_CANDIDATE => "candidate",
      STATUS_DELEGATE => "delegate",
      STATUS_JOURNALIST => "journalist",
      STATUS_COORD => "coord"
    }
  end

  def self.previous_statuses_methods
    self.all_previous_statuses.values.collect{ |v| "was_#{v}" }
  end

  def self.social_methods
    SOCIAL_ACCOUNTS.keys.collect{ |v| "social_#{v}" }
  end

  def self.all_statuses
    all_future_statuses.merge(all_previous_statuses).merge(NO_STATUS => "no_status")
  end

  def confirm!
    update_attributes! confirmed_at: Time.now
  end

  def confirmed?
    confirmed_at ? true : false
  end

  def can_be(status_value)
    desired_statuses & status_value == status_value
  end

  def was(status_value)
    previous_statuses & status_value == status_value
  end


  self.all_future_statuses_with_archived.each do |status_value, status_name|
    method_n = "can_be_#{status_name}"
    define_method(method_n) { can_be status_value }
    define_method("#{method_n}=") do |val|
      if val == "1" || val == true
        self.desired_statuses |= status_value
      else
        self.desired_statuses &= ~status_value
      end
    end
  end

  self.all_previous_statuses.each do |status_value, status_name|
    method_n = "was_#{status_name}"
    define_method(method_n) { was status_value }
    define_method("#{method_n}=") do |val|
      if val == '1' || val == true
        self.previous_statuses |= status_value
      else
        self.previous_statuses &= ~status_value
      end
    end
  end

  def send_email_confirmation
		#temporarily skipping email confirmation
		#self.confirmation_token = SecureRandom.hex(16)
    save
    #ConfirmationMailer.email_confirmation(self).deliver
  end

  def verified?
		#temporarily skipping phone confirmation
		true
		skip_phone_verification || (verification.present? && verification.confirmed? && verification.phone_number == self.phone)
  end

  def reviewed?
    approved?
  end

  def confirm_email!
    self.update_attributes! confirmed_at: Time.now
  end

  def confirm_phone!
    self.update_attributes! phone_verified: true
  end

  def phone=(value)
    self[:phone] = Verification.normalize_phone_number(value)
  end

  def imported?
    @imported
  end

  def imported!
    @imported = true
  end

  def can_not_be_approved?
    return :valid unless valid?
    return :approved if state_name == :approved
    return :email_missing unless email.present?
    return :email if UserApp.where('id != ?', id || 0).where('email = ?', email).count > 0
    return :phone if UserApp.where('id != ?', id || 0).where('phone = ?', phone).count > 0
    false
  end

  ransacker :phone, :formatter => proc {|s| Verification.normalize_phone_number(s) }

  # Разбивает содержимое поля uic на отдельные номера:
  # '1234,1235,1236' => '(1234),(1235),(1236)''
  #
  # В результате ransacker работает для:
  #   uic_matcher_contains - возвращает true, если uic содержит искомый номер
  #   uic_matcher_equals - возвращает true, если uic состоит в точности из одного искомого номера
  #
  ransacker :uic_matcher, type: :string, formatter: ->(str){ '('+str+')' } do |parent|
    Arel::Nodes::NamedFunction.new( 'regexp_replace', [ parent.table[:uic], '[0-9]+', '(\\&)', 'g' ] )
  end

  def blacklisted
    Blacklist.find_by_phone(phone)
  end

  def valid_social_link?(profile_link, network = nil)
    profile_link.starts_with?('http://') || profile_link.starts_with?('https://')
  end

  private

  def set_phone_verified_status
    self.phone_verified = verified?
    true
  end

  def check_regions
    errors.add(:region, 'Район должен принадлежать выбранному округу') if region && region.parent != adm_region
  end

  def check_phone_verified
    errors.add(:phone, 'не подтвержден') unless verified?
  end

  def check_uic_belongs_to_region
    return true unless uic.present?
    uic.to_s.split(',').each do |uic_number|
      tmp_uic = Uic.find_by( number: uic_number )
      if !tmp_uic.present?
        errors.add(:uic, "УИК №#{uic_number} не найден")
      elsif region.present? && !tmp_uic.belongs_to_region?( region )
        errors.add(:uic, "Район УИК №#{uic_number} и район пользователя не совпадают")
      elsif adm_region.present? && !tmp_uic.belongs_to_region?( adm_region )
        errors.add(:uic, "Адм.округ УИК №#{uic_number} и пользователя не совпадают")
      end
    end
    true
  end


end
