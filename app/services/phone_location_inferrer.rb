# frozen_string_literal: true

# Infers a contact's country (via ISO country code) and — for Brazilian
# phone numbers — a rough city based on the DDD area code. Used on contact
# creation so the "Localização" fields on the profile are populated
# automatically without the agent having to type them.
#
# Returns nil for anything it can't confidently infer.
class PhoneLocationInferrer
  # Minimal DDD → city map. Kept intentionally small; add as needed.
  # Source: ANATEL area code assignments (capitals + major cities).
  BRAZIL_DDD_CITIES = {
    '11' => { city: 'São Paulo', state: 'SP' },
    '12' => { city: 'São José dos Campos', state: 'SP' },
    '13' => { city: 'Santos', state: 'SP' },
    '14' => { city: 'Bauru', state: 'SP' },
    '15' => { city: 'Sorocaba', state: 'SP' },
    '16' => { city: 'Ribeirão Preto', state: 'SP' },
    '17' => { city: 'São José do Rio Preto', state: 'SP' },
    '18' => { city: 'Presidente Prudente', state: 'SP' },
    '19' => { city: 'Campinas', state: 'SP' },
    '21' => { city: 'Rio de Janeiro', state: 'RJ' },
    '22' => { city: 'Campos dos Goytacazes', state: 'RJ' },
    '24' => { city: 'Volta Redonda', state: 'RJ' },
    '27' => { city: 'Vitória', state: 'ES' },
    '28' => { city: 'Cachoeiro de Itapemirim', state: 'ES' },
    '31' => { city: 'Belo Horizonte', state: 'MG' },
    '32' => { city: 'Juiz de Fora', state: 'MG' },
    '33' => { city: 'Governador Valadares', state: 'MG' },
    '34' => { city: 'Uberlândia', state: 'MG' },
    '35' => { city: 'Poços de Caldas', state: 'MG' },
    '37' => { city: 'Divinópolis', state: 'MG' },
    '38' => { city: 'Montes Claros', state: 'MG' },
    '41' => { city: 'Curitiba', state: 'PR' },
    '42' => { city: 'Ponta Grossa', state: 'PR' },
    '43' => { city: 'Londrina', state: 'PR' },
    '44' => { city: 'Maringá', state: 'PR' },
    '45' => { city: 'Foz do Iguaçu', state: 'PR' },
    '46' => { city: 'Francisco Beltrão', state: 'PR' },
    '47' => { city: 'Joinville', state: 'SC' },
    '48' => { city: 'Florianópolis', state: 'SC' },
    '49' => { city: 'Chapecó', state: 'SC' },
    '51' => { city: 'Porto Alegre', state: 'RS' },
    '53' => { city: 'Pelotas', state: 'RS' },
    '54' => { city: 'Caxias do Sul', state: 'RS' },
    '55' => { city: 'Santa Maria', state: 'RS' },
    '61' => { city: 'Brasília', state: 'DF' },
    '62' => { city: 'Goiânia', state: 'GO' },
    '63' => { city: 'Palmas', state: 'TO' },
    '64' => { city: 'Rio Verde', state: 'GO' },
    '65' => { city: 'Cuiabá', state: 'MT' },
    '66' => { city: 'Rondonópolis', state: 'MT' },
    '67' => { city: 'Campo Grande', state: 'MS' },
    '68' => { city: 'Rio Branco', state: 'AC' },
    '69' => { city: 'Porto Velho', state: 'RO' },
    '71' => { city: 'Salvador', state: 'BA' },
    '73' => { city: 'Ilhéus', state: 'BA' },
    '74' => { city: 'Juazeiro', state: 'BA' },
    '75' => { city: 'Feira de Santana', state: 'BA' },
    '77' => { city: 'Vitória da Conquista', state: 'BA' },
    '79' => { city: 'Aracaju', state: 'SE' },
    '81' => { city: 'Recife', state: 'PE' },
    '82' => { city: 'Maceió', state: 'AL' },
    '83' => { city: 'João Pessoa', state: 'PB' },
    '84' => { city: 'Natal', state: 'RN' },
    '85' => { city: 'Fortaleza', state: 'CE' },
    '86' => { city: 'Teresina', state: 'PI' },
    '87' => { city: 'Petrolina', state: 'PE' },
    '88' => { city: 'Juazeiro do Norte', state: 'CE' },
    '89' => { city: 'Picos', state: 'PI' },
    '91' => { city: 'Belém', state: 'PA' },
    '92' => { city: 'Manaus', state: 'AM' },
    '93' => { city: 'Santarém', state: 'PA' },
    '94' => { city: 'Marabá', state: 'PA' },
    '95' => { city: 'Boa Vista', state: 'RR' },
    '96' => { city: 'Macapá', state: 'AP' },
    '97' => { city: 'Coari', state: 'AM' },
    '98' => { city: 'São Luís', state: 'MA' },
    '99' => { city: 'Imperatriz', state: 'MA' }
  }.freeze

  def self.call(phone_number)
    new(phone_number).call
  end

  def initialize(phone_number)
    @raw = phone_number.to_s
  end

  def call
    return {} if digits.blank?

    result = {}
    country = country_code_from_phone
    result[:country_code] = country if country.present?

    if country == 'BR'
      brazilian = brazilian_city
      result.merge!(brazilian) if brazilian.any?
    end

    result
  end

  private

  def digits
    @digits ||= @raw.gsub(/\D/, '')
  end

  # Uses the telephone_number gem when available; falls back to a simple
  # prefix check (Brazil) so this works even if the gem isn't loaded in
  # some environments.
  def country_code_from_phone
    if defined?(TelephoneNumber)
      parsed = TelephoneNumber.parse("+#{digits}")
      return parsed.country if parsed&.valid?
    end
    return 'BR' if digits.start_with?('55') && digits.length.between?(12, 13)

    nil
  rescue StandardError
    nil
  end

  # Assumes the number arrived as 55DDDNNNNNNNN (12 or 13 digits total).
  def brazilian_city
    return {} unless digits.start_with?('55') && digits.length.between?(12, 13)

    ddd = digits[2, 2]
    entry = BRAZIL_DDD_CITIES[ddd]
    return {} unless entry

    { city: entry[:city], state: entry[:state] }
  end
end
