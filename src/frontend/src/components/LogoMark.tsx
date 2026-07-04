interface LogoMarkProps {
  size?: number;
}

export default function LogoMark({ size = 50 }: LogoMarkProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
      <path d="M38 35 L38 15" stroke="#5b5fe6" strokeWidth="6" strokeLinecap="round" fill="none"/>
      <path d="M162 35 L162 15" stroke="#5b5fe6" strokeWidth="6" strokeLinecap="round" fill="none"/>
      <circle cx="56" cy="90" r="34" fill="none" stroke="#5b5fe6" strokeWidth="6"/>
      <circle cx="144" cy="90" r="34" fill="none" stroke="#5b5fe6" strokeWidth="6"/>
      <path d="M60 66 L44 90 L58 90 L50 114 L68 86 L54 86 Z" fill="#1f9d6f" strokeWidth="0"/>
      <path d="M148 66 L132 90 L146 90 L138 114 L156 86 L142 86 Z" fill="#1f9d6f" strokeWidth="0"/>
      <path d="M90 130 L100 145 L110 130 Z" fill="#5b5fe6" strokeWidth="0"/>
    </svg>
  );
}
