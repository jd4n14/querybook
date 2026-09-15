package results

import (
	"fmt"
	"math/big"
	"reflect"

	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/common/types/traits"
)

// decimalVal is an exact rational for SQL DECIMAL/NUMERIC cells. It is a
// temporary CEL view: the retained cell text is never rewritten.
type decimalVal struct {
	rat *big.Rat
	raw string
}

var decimalType = types.NewOpaqueType("decimal").WithTraits(traits.ComparerType)

func parseDecimal(raw string) (decimalVal, bool) {
	rat, ok := new(big.Rat).SetString(raw)
	if !ok || rat == nil {
		return decimalVal{}, false
	}
	return decimalVal{rat: rat, raw: raw}, true
}

func (d decimalVal) ConvertToNative(typeDesc reflect.Type) (any, error) {
	switch typeDesc.Kind() {
	case reflect.String:
		return d.raw, nil
	case reflect.Interface:
		if typeDesc.NumMethod() == 0 {
			return d.rat, nil
		}
	}
	return nil, fmt.Errorf("decimal: cannot convert to %s", typeDesc)
}

func (d decimalVal) ConvertToType(typeVal ref.Type) ref.Val {
	switch typeVal {
	case types.StringType:
		return types.String(d.raw)
	case types.DoubleType:
		f, _ := d.rat.Float64()
		return types.Double(f)
	case types.IntType:
		if d.rat.IsInt() && d.rat.Num().IsInt64() {
			return types.Int(d.rat.Num().Int64())
		}
		return types.NewErr("decimal: not an integer")
	case types.TypeType:
		return decimalType
	default:
		return types.NewErr("decimal: unsupported conversion to %s", typeVal.TypeName())
	}
}

func (d decimalVal) Equal(other ref.Val) ref.Val {
	cmp := d.Compare(other)
	if types.IsError(cmp) {
		return types.False
	}
	i, ok := cmp.(types.Int)
	return types.Bool(ok && i == types.IntZero)
}

func (d decimalVal) Type() ref.Type { return decimalType }

func (d decimalVal) Value() any { return d.raw }

func (d decimalVal) Compare(other ref.Val) ref.Val {
	switch ov := other.(type) {
	case decimalVal:
		return types.Int(d.rat.Cmp(ov.rat))
	case types.Int:
		return types.Int(d.rat.Cmp(new(big.Rat).SetInt64(int64(ov))))
	case types.Uint:
		return types.Int(d.rat.Cmp(new(big.Rat).SetUint64(uint64(ov))))
	case types.Double:
		// Mixed DECIMAL vs double uses IEEE 754 on the decimal's float64
		// approximation against the double operand. DECIMAL vs DECIMAL and
		// DECIMAL vs int remain exact rationals.
		f, exact := d.rat.Float64()
		_ = exact
		return types.Double(f).Compare(ov)
	default:
		return types.MaybeNoSuchOverloadErr(other)
	}
}
